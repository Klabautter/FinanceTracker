import SwiftUI

@MainActor
@Observable
final class TransactionSplitEditorModel {
    let parent: Transaction

    let dependencies: AppDependencies
    private let locale: Locale
    private var originalLines: [TransactionSplitLine] = []

    var lines: [TransactionSplitLine] = []
    private(set) var amountTexts: [UUID: String] = [:]
    private(set) var leafCategories: [Category] = []
    private(set) var validationMessage: String?
    private(set) var isLoading = false
    private(set) var isSaving = false

    init(parent: Transaction, dependencies: AppDependencies, locale: Locale = .current) {
        self.parent = parent
        self.dependencies = dependencies
        self.locale = locale
    }

    var parentMagnitude: Decimal {
        abs(parent.amount.amount)
    }

    var remainder: Decimal {
        parentMagnitude - parsedAmounts.values.reduce(into: Decimal(0)) { $0 += $1 }
    }

    var canSave: Bool {
        guard !isLoading, !isSaving, !lines.isEmpty, parsedAmounts.count == lines.count else {
            return false
        }
        return remainder == 0 && parsedAmounts.values.allSatisfy { $0 > 0 }
    }

    func amountText(for lineID: UUID) -> String {
        amountTexts[lineID] ?? ""
    }

    func setAmountText(_ text: String, for lineID: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        amountTexts[lineID] = text
        guard let amount = Self.parseAmountText(text) else {
            validationMessage = String(localized: "Bitte für jede Position einen gültigen Betrag eingeben.")
            return
        }
        lines[index].amount = amount
        validationMessage = nil
    }

    func addLine() {
        let suggested = max(0, remainder)
        let line = TransactionSplitLine(parentTransactionID: parent.id, amount: suggested)
        lines.append(line)
        amountTexts[line.id] = Self.editableAmountString(suggested, locale: locale)
    }

    func removeLines(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where lines.indices.contains(index) {
            amountTexts.removeValue(forKey: lines[index].id)
            lines.remove(at: index)
        }
        validationMessage = nil
    }

    /// Eine im Split angelegte Kategorie steht sofort allen Positionen zur Wahl.
    func categoryCreated(_ category: Category) {
        guard !leafCategories.contains(where: { $0.id == category.id }) else { return }
        leafCategories.append(category)
        leafCategories.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        validationMessage = nil
        defer { isLoading = false }

        do {
            async let categoriesTask = dependencies.categoryRepository.categories()
            async let splitsTask = dependencies.transactionSplitRepository.splitLines(
                parentTransactionID: parent.id
            )
            let allCategories = try await categoriesTask
            let existing = try await splitsTask
            guard !Task.isCancelled else { return }

            leafCategories = allCategories
                .filter { category in
                    !allCategories.contains { $0.parentID == category.id }
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            originalLines = existing
            lines = existing.isEmpty
                ? [TransactionSplitLine(parentTransactionID: parent.id, amount: parentMagnitude)]
                : existing
            amountTexts = Dictionary(uniqueKeysWithValues: lines.map {
                ($0.id, Self.editableAmountString($0.amount, locale: locale))
            })
        } catch {
            validationMessage = String(localized: "Split-Daten konnten nicht geladen werden.")
        }
    }

    func save() async -> Bool {
        guard !isSaving else { return false }
        guard let validatedLines = validatedLines() else {
            validationMessage = String(localized: "Bitte für jede Position einen gültigen positiven Betrag eingeben.")
            return false
        }
        switch TransactionSplitValidator.validate(lines: validatedLines, parent: parent) {
        case .invalid(let message):
            validationMessage = message
            return false
        case .valid:
            break
        }

        isSaving = true
        validationMessage = nil
        defer { isSaving = false }

        do {
            let currentIDs = Set(validatedLines.map(\.id))
            let removedExistingLine = originalLines.contains { !currentIDs.contains($0.id) }
            if removedExistingLine {
                try await replaceLinesWithRollback(validatedLines)
            } else {
                // Reine Änderungen und Ergänzungen können ohne vorheriges Löschen upserted werden.
                try await dependencies.transactionSplitRepository.upsert(validatedLines)
            }
            lines = validatedLines
            originalLines = validatedLines
            dependencies.changeTracker.markChanged()
            return true
        } catch {
            validationMessage = String(localized: "Speichern fehlgeschlagen. Die bisherigen Split-Positionen wurden beibehalten.")
            return false
        }
    }

    static func editableAmountString(_ amount: Decimal, locale: Locale) -> String {
        let canonical = NSDecimalNumber(decimal: amount).stringValue
        guard let separator = locale.decimalSeparator, separator != "." else { return canonical }
        return canonical.replacingOccurrences(of: ".", with: separator)
    }

    static func parseAmountText(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789.,-")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return DecimalParser.parse(trimmed)
    }

    private var parsedAmounts: [UUID: Decimal] {
        Dictionary(uniqueKeysWithValues: lines.compactMap { line in
            guard let text = amountTexts[line.id],
                  let amount = Self.parseAmountText(text) else { return nil }
            return (line.id, amount)
        })
    }

    private func validatedLines() -> [TransactionSplitLine]? {
        let amounts = parsedAmounts
        guard amounts.count == lines.count else { return nil }
        var validated = lines
        for index in validated.indices {
            guard let amount = amounts[validated[index].id], amount > 0 else { return nil }
            validated[index].amount = amount
        }
        return validated
    }

    private func replaceLinesWithRollback(_ replacement: [TransactionSplitLine]) async throws {
        let previous = originalLines
        // Erst nach einem erfolgreichen Upsert der validierten Daten löschen.
        // Alte, entfernte IDs bleiben bis dahin als rückholbarer Bestand erhalten.
        try await dependencies.transactionSplitRepository.upsert(replacement)
        try await dependencies.transactionSplitRepository.deleteAll(parentTransactionID: parent.id)
        do {
            try await dependencies.transactionSplitRepository.upsert(replacement)
        } catch {
            try? await dependencies.transactionSplitRepository.deleteAll(parentTransactionID: parent.id)
            try? await dependencies.transactionSplitRepository.upsert(previous)
            throw error
        }
    }
}

/// Split-Editor (Roadmap #70): Beträge auf Kategorien aufteilen.
/// Speichern nur bei erfüllter Invariant (Roadmap #69).
struct TransactionSplitSheet: View {
    let parent: Transaction
    let dependencies: AppDependencies
    let onSaved: () -> Void

    @State private var model: TransactionSplitEditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyPresentationState.self) private var privacyState

    init(parent: Transaction, dependencies: AppDependencies, onSaved: @escaping () -> Void) {
        self.parent = parent
        self.dependencies = dependencies
        self.onSaved = onSaved
        _model = State(initialValue: TransactionSplitEditorModel(parent: parent, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var model = model

        AdaptiveSheet(title: String(localized: "Splitten")) {
            Form {
                Section("Split") {
                    HStack {
                        Text(parent.effectiveMerchantName)
                            .lineLimit(1)
                        Spacer()
                        Text(PrivacyAwareMoney.decimalString(model.parentMagnitude, currency: parent.amount.currency, privacy: privacyState))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Positionen") {
                    ForEach($model.lines) { $line in
                        HStack {
                            CategorySelectionPicker(
                                title: String(localized: "Kategorie der Split-Position"),
                                selection: $line.categoryID,
                                categories: model.leafCategories,
                                dependencies: model.dependencies,
                                onCreated: { model.categoryCreated($0) }
                            )
                            Spacer()
                            TextField("0,00", text: amountBinding(line.id))
                                .multilineTextAlignment(.trailing)
                                .font(.callout.monospacedDigit())
                                .frame(width: 90)
                                .accessibilityLabel("Betrag der Split-Position")
                        }
                    }
                    .onDelete { offsets in
                        model.removeLines(at: offsets)
                    }

                    Button {
                        model.addLine()
                    } label: {
                        Label("Position hinzufügen", systemImage: "plus.circle")
                    }

                    LabeledContent("Rest") {
                        Text(PrivacyAwareMoney.decimalString(model.remainder, currency: parent.amount.currency, privacy: privacyState))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(model.remainder == 0 ? AppPalette.positive : AppPalette.critical)
                    }
                }

                if let validationMessage = model.validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppPalette.critical)
                }

                Section {
                    Text("Die Summe der Positionen muss exakt dem Transaktionsbetrag entsprechen. Die Split-Positionen ersetzen die Original-Buchung in Budgets und Analysen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Button("Speichern") {
                        Task {
                            if await model.save() {
                                onSaved()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
        }
        .task(id: parent.id) { await model.load() }
        #if os(macOS)
        .frame(width: 520, height: 480)
        #endif
    }

    private func amountBinding(_ lineID: UUID) -> Binding<String> {
        Binding(
            get: { model.amountText(for: lineID) },
            set: { model.setAmountText($0, for: lineID) }
        )
    }
}
