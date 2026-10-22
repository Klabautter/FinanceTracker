import SwiftUI

/// Rule Builder V1 (Roadmap #55–57): verständliche Bedingungen, Ziel-
/// Kategorie, Live-Preview über Pushdown-Query, keine nackten Prioritäten.
struct RuleBuilderSheet: View {
    let dependencies: AppDependencies
    let onSaved: () -> Void

    private enum ConditionType: String, CaseIterable, Identifiable {
        case merchantContains = "Händler enthält"
        case merchantEquals = "Händler ist"
        case descriptionContains = "Beschreibung enthält"
        var id: Self { self }

        var title: String {
            switch self {
            case .merchantContains: String(localized: "Händler enthält")
            case .merchantEquals: String(localized: "Händler ist")
            case .descriptionContains: String(localized: "Beschreibung enthält")
            }
        }
    }

    @State private var conditionType: ConditionType = .merchantContains
    @State private var conditionValue = ""
    @State private var selectedCategoryID: UUID?
    @State private var categories: [Category] = []
    @State private var preview: RulePreview?
    @State private var isPreviewLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    struct RulePreview: Sendable {
        let totalCount: Int
        let samples: [Transaction]
    }

    private var canSave: Bool {
        !conditionValue.trimmingCharacters(in: .whitespaces).isEmpty && selectedCategoryID != nil
    }

    var body: some View {
        AdaptiveSheet(title: String(localized: "Neue Regel")) {
            Form {
                Section("Wenn") {
                    Picker("Bedingung", selection: $conditionType) {
                        ForEach(ConditionType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    TextField("Wert", text: $conditionValue)
                        .onSubmit { Task { await loadPreview() } }
                }

                Section("Dann Kategorie") {
                    CategorySelectionPicker(
                        title: String(localized: "Kategorie"),
                        selection: $selectedCategoryID,
                        categories: categories,
                        dependencies: dependencies,
                        noneTitle: String(localized: "Bitte auswählen"),
                        showsIcons: true
                    )
                }

                Section("Vorschau") {
                    if isPreviewLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Prüfe Treffer…")
                        }
                    } else if let preview {
                        (preview.totalCount == 1
                            ? Text("Diese Regel trifft auf 1 Transaktion zu.")
                            : Text("Diese Regel trifft auf \(preview.totalCount) Transaktionen zu."))
                            .font(.callout.weight(.medium))

                        ForEach(preview.samples.prefix(5)) { txn in
                            HStack {
                                Text(txn.effectiveMerchantName)
                                    .lineLimit(1)
                                Spacer()
                                MoneyText(money: txn.amount, signed: true)
                                    .font(.callout.monospacedDigit())
                            }
                            .font(.caption)
                        }

                        if preview.totalCount > preview.samples.count {
                            Text("… und \(preview.totalCount - preview.samples.count) weitere")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Wert eingeben, um Treffer zu sehen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppPalette.critical)
                }
            }
            .financeFormStyle()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(!canSave)
                }
            }
            .onChange(of: conditionType) { _, _ in
                preview = nil
            }
            .onChange(of: conditionValue) { _, _ in
                preview = nil
            }
            .task { await loadCategories() }
        }
        #if os(macOS)
        .frame(width: 460, height: 480)
        #endif
    }

    private func loadCategories() async {
        do {
            let all = try await dependencies.categoryRepository.categories()
            // WP12: Leaf-only: Regel-Zielkategorien sind zuweisbare Leaves.
            // Parents ohne Kinder verhalten sich als wählbares Leaf.
            categories = CategoryHierarchy().assignableCategories(in: all)
            if selectedCategoryID == nil, let firstLeaf = categories.first {
                selectedCategoryID = firstLeaf.id
            }
        } catch {
            errorMessage = String(localized: "Kategorien konnten nicht geladen werden.")
        }
    }

    private func loadPreview() async {
        let value = conditionValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            preview = nil
            return
        }
        isPreviewLoading = true
        defer { isPreviewLoading = false }

        do {
            // Pushdown: Suche läuft in der DB (searchableText).
            var query = TransactionQuery()
            query.searchText = value.lowercased()
            let candidates = try await dependencies.transactionRepository.transactions(matching: query)

            let condition = makeCondition(value: value)
            let engine = CategoryRuleEngine()
            let matches = candidates.filter { txn in
                engine.firstMatch(in: [CategoryRule(id: UUID(), priority: 0, condition: condition, categoryID: UUID())], for: txn) != nil
            }

            preview = RulePreview(
                totalCount: matches.count,
                samples: Array(matches.prefix(5))
            )
        } catch {
            errorMessage = String(localized: "Vorschau konnte nicht geladen werden.")
        }
    }

    private func makeCondition(value: String) -> RuleCondition {
        switch conditionType {
        case .merchantContains: .merchantContains(value)
        case .merchantEquals: .merchantEquals(value)
        case .descriptionContains: .descriptionContains(value)
        }
    }

    private func save() {
        guard let categoryID = selectedCategoryID else { return }
        let value = conditionValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }

        Task {
            do {
                let existing = try await dependencies.ruleRepository.rules()
                let maxPriority = existing.map(\.priority).max() ?? 100
                let rule = CategoryRule(
                    priority: maxPriority + 10,
                    condition: makeCondition(value: value),
                    categoryID: categoryID,
                    origin: .user
                )
                try await dependencies.ruleRepository.upsert([rule])
                onSaved()
                dismiss()
            } catch {
                errorMessage = String(localized: "Regel konnte nicht gespeichert werden.")
            }
        }
    }
}
