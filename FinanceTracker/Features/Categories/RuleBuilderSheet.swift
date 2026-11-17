import SwiftUI

/// Rule Builder V1 (Roadmap #55–57): verständliche Bedingungen, Ziel-
/// Kategorie, Live-Preview über Pushdown-Query, keine nackten Prioritäten.
struct RuleBuilderSheet: View {
    let dependencies: AppDependencies
    let onSaved: () -> Void

    @State private var model: RuleBuilderModel
    @Environment(\.dismiss) private var dismiss

    init(dependencies: AppDependencies, onSaved: @escaping () -> Void) {
        self.dependencies = dependencies
        self.onSaved = onSaved
        _model = State(initialValue: RuleBuilderModel(dependencies: dependencies))
    }

    var body: some View {
        AdaptiveSheet(title: String(localized: "Neue Regel")) {
            Form {
                Section("Wenn") {
                    Picker("Bedingung", selection: $model.conditionType) {
                        ForEach(RuleBuilderModel.ConditionType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    TextField("Wert", text: $model.conditionValue)
                        .onSubmit { Task { await model.loadPreview() } }
                }

                Section("Dann Kategorie") {
                    CategorySelectionPicker(
                        title: String(localized: "Kategorie"),
                        selection: $model.selectedCategoryID,
                        categories: model.categories,
                        dependencies: dependencies,
                        noneTitle: String(localized: "Bitte auswählen"),
                        showsIcons: true
                    )
                }

                Section("Vorschau") {
                    if model.isPreviewLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Prüfe Treffer…")
                        }
                    } else if let preview = model.preview {
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

                if let errorMessage = model.loadState.failureMessage ?? model.actionError {
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
                    Button("Speichern") { Task { await save() } }
                        .disabled(!model.canSave || model.isSaving)
                }
            }
            .onChange(of: model.conditionType) { _, _ in
                model.resetPreview()
            }
            .onChange(of: model.conditionValue) { _, _ in
                model.resetPreview()
            }
            .task { await model.loadCategories() }
        }
        #if os(macOS)
        .frame(width: 460, height: 480)
        #endif
    }

    private func save() async {
        guard await model.save() else { return }
        onSaved()
        dismiss()
    }
}

/// Zustand und Abläufe des Regel-Editors (AGENTS.md Regeln 1 und 37).
@MainActor
@Observable
final class RuleBuilderModel {
    /// Nur, was dieses Model nutzt (Roadmap 7.4, `DependencyCapabilities`).
    typealias Dependencies = any HasCategoryRepository & HasRuleRepository & HasTransactionRepository

    enum ConditionType: String, CaseIterable, Identifiable {
        case merchantContains
        case merchantEquals
        case descriptionContains
        var id: Self { self }

        var title: String {
            switch self {
            case .merchantContains: String(localized: "Händler enthält")
            case .merchantEquals: String(localized: "Händler ist")
            case .descriptionContains: String(localized: "Beschreibung enthält")
            }
        }
    }

    struct RulePreview: Sendable {
        let totalCount: Int
        let samples: [Transaction]
    }

    var conditionType: ConditionType = .merchantContains
    var conditionValue = ""
    var selectedCategoryID: UUID?
    private(set) var categories: [Category] = []
    private(set) var preview: RulePreview?
    private(set) var isPreviewLoading = false
    private(set) var isSaving = false
    private(set) var loadState: LoadState = .idle
    private(set) var actionError: String?
    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var trimmedValue: String { conditionValue.trimmingCharacters(in: .whitespaces) }

    var canSave: Bool { !trimmedValue.isEmpty && selectedCategoryID != nil }

    func resetPreview() {
        preview = nil
    }

    func loadCategories() async {
        loadState = .loading
        do {
            let all = try await dependencies.categoryRepository.categories()
            // WP12: Leaf-only: Regel-Zielkategorien sind zuweisbare Leaves.
            // Parents ohne Kinder verhalten sich als wählbares Leaf.
            categories = CategoryHierarchy().assignableCategories(in: all)
            if selectedCategoryID == nil, let firstLeaf = categories.first {
                selectedCategoryID = firstLeaf.id
            }
            loadState = .loaded
        } catch {
            loadState = .failed(String(localized: "Kategorien konnten nicht geladen werden."))
        }
    }

    func loadPreview() async {
        let value = trimmedValue
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

            let rule = CategoryRule(id: UUID(), priority: 0, condition: makeCondition(value: value), categoryID: UUID())
            let engine = CategoryRuleEngine()
            let matches = candidates.filter { engine.firstMatch(in: [rule], for: $0) != nil }
            preview = RulePreview(totalCount: matches.count, samples: Array(matches.prefix(5)))
            actionError = nil
        } catch {
            actionError = String(localized: "Vorschau konnte nicht geladen werden.")
        }
    }

    func makeCondition(value: String) -> RuleCondition {
        switch conditionType {
        case .merchantContains: .merchantContains(value)
        case .merchantEquals: .merchantEquals(value)
        case .descriptionContains: .descriptionContains(value)
        }
    }

    /// Neue Nutzerregeln kommen hinter alle bestehenden, damit sie keine
    /// bestehende Zuordnung still überstimmen. `true` nach dem Speichern.
    func save() async -> Bool {
        guard let categoryID = selectedCategoryID, !trimmedValue.isEmpty else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let existing = try await dependencies.ruleRepository.rules()
            let maxPriority = existing.map(\.priority).max() ?? 100
            let rule = CategoryRule(
                priority: maxPriority + 10,
                condition: makeCondition(value: trimmedValue),
                categoryID: categoryID,
                origin: .user
            )
            try await dependencies.ruleRepository.upsert([rule])
            actionError = nil
            return true
        } catch {
            actionError = String(localized: "Regel konnte nicht gespeichert werden.")
            return false
        }
    }
}
