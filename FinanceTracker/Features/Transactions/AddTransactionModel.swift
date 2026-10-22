import Foundation

/// Manual Transactions (Roadmap #72–75): Ausgabe, Einnahme und Transfer-Paare.
@MainActor
@Observable
final class AddTransactionModel {
    enum EntryKind: String, CaseIterable, Identifiable {
        case expense = "Ausgabe"
        case income = "Einnahme"
        case transfer = "Transfer"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .expense: String(localized: "Ausgabe")
            case .income: String(localized: "Einnahme")
            case .transfer: String(localized: "Transfer")
            }
        }
    }

    struct TransferDraft {
        var fromAccountID: UUID?
        var toAccountID: UUID?
    }

    var transferDraft = TransferDraft()

    struct Draft {
        var kind: EntryKind = .expense
        var amountText: String = ""
        var merchant: String = ""
        var accountID: UUID?
        var categoryID: UUID?
        var tagIDs: [UUID] = []
        var date: Date = Date()
        var note: String = ""
    }

    private let dependencies: AppDependencies
    /// Gesetzt im Bearbeiten-Modus: die bestehende manuelle Buchung.
    let editing: Transaction?
    var isEditing: Bool { editing != nil }
    private let primaryTransactionID = UUID()
    private let transferCounterpartID = UUID()
    private let manualExternalID = "manual-\(UUID().uuidString)"

    private(set) var accounts: [Account] = []
    private(set) var leafCategories: [Category] = []
    /// Regeln + Branchenwörter für den Kategorie-Vorschlag beim Tippen.
    private var compiledRules: CategoryRuleEngine.CompiledRules?

    /// Ohne gewählte Kategorie: was die Automatik aus dem Händlernamen
    /// machen würde (wie bei importierten Buchungen). Wird beim Speichern
    /// übernommen, solange der Nutzer nichts anderes wählt.
    var suggestedCategory: Category? {
        guard draft.categoryID == nil, draft.kind != .transfer, let compiledRules else { return nil }
        let merchant = draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard merchant.count >= 3 else { return nil }
        var probe = Transaction(
            accountID: draft.accountID ?? UUID(),
            source: .manual,
            kind: draft.kind == .income ? .income : .purchase,
            amount: Money(amount: draft.kind == .income ? 1 : -1, currency: .eur),
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
        guard compiledRules.apply(to: &probe), let categoryID = probe.categoryID else { return nil }
        return categoryOptions.first { $0.id == categoryID }
    }

    /// Erstes Konto direkt im Formular: Bargeld, sofort ausgewählt.
    func createCashAccount() async {
        let account = Account(name: String(localized: "Bargeld"), type: .cash, currency: dependencies.baseCurrency, source: .manual)
        do {
            try await dependencies.accountRepository.upsert([account])
            accounts.append(account)
            draft.accountID = account.id
            dependencies.changeTracker.markChanged()
        } catch {
            errorMessage = String(localized: "Das Konto konnte nicht angelegt werden.")
        }
    }

    /// Zur gewählten Art passende Kategorien: Eine Ausgabe gehört weder zu
    /// „Einkünfte" noch zu „Umbuchungen", eine Einnahme nicht zu
    /// „Umbuchungen". Eine bereits gesetzte Kategorie bleibt beim Bearbeiten
    /// wählbar, solange die Art nicht gewechselt wird.
    var categoryOptions: [Category] {
        let excluded = Self.excludedCategoryIDs(for: draft.kind)
        let kept = editing.flatMap { $0.categoryID == draft.categoryID ? $0.categoryID : nil }
        return leafCategories.filter { !excluded.contains($0.id) || $0.id == kept }
    }

    /// Eine im Formular neu angelegte Kategorie aufnehmen und auswählen.
    func categoryCreated(_ category: Category) {
        if !leafCategories.contains(where: { $0.id == category.id }) {
            leafCategories.append(category)
            leafCategories.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        draft.categoryID = category.id
    }

    var dependenciesForCategoryEditor: AppDependencies { dependencies }

    /// Nach einem Wechsel der Art: Kategorie leeren, wenn sie nicht mehr passt.
    func dropUnavailableCategory() {
        guard let categoryID = draft.categoryID,
              Self.excludedCategoryIDs(for: draft.kind).contains(categoryID) else { return }
        draft.categoryID = nil
    }

    private static func excludedCategoryIDs(for kind: EntryKind) -> Set<UUID> {
        switch kind {
        case .expense: [Category.income.id, Category.transfers.id]
        case .income: [Category.transfers.id]
        case .transfer: []
        }
    }
    private(set) var tags: [Tag] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private var didSave = false

    var draft = Draft()

    init(dependencies: AppDependencies, editing: Transaction? = nil) {
        self.dependencies = dependencies
        self.editing = editing
        if let editing {
            draft = Draft(
                kind: editing.amount.isNegative ? .expense : .income,
                amountText: Self.editText(for: abs(editing.amount.amount)),
                merchant: editing.effectiveMerchantName,
                accountID: editing.accountID,
                categoryID: editing.categoryID,
                tagIDs: editing.tagIDs ?? [],
                date: editing.displayDate,
                note: editing.note ?? ""
            )
        }
    }

    /// Betrag als reine Eingabezahl mit Komma (ohne Währung/Tausenderpunkte).
    static func editText(for amount: Decimal) -> String {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        let text = NSDecimalNumber(decimal: rounded).stringValue
        return text.replacingOccurrences(of: ".", with: ",")
    }

    var canSave: Bool {
        guard !isSaving, !didSave, DecimalParser.parse(draft.amountText).map({ $0 > 0 }) == true else {
            return false
        }
        if draft.kind == .transfer {
            return transferDraft.fromAccountID != nil
                && transferDraft.toAccountID != nil
                && transferDraft.fromAccountID != transferDraft.toAccountID
        }
        return !draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.accountID != nil
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let accountsTask = dependencies.accountRepository.accounts()
            async let categoriesTask = dependencies.categoryRepository.categories()
            async let tagsTask = dependencies.tagRepository.tags()

            accounts = try await accountsTask
                .filter(\.isActive)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let all = try await categoriesTask
            // Leaf-only (Roadmap #43): nur zuweisbare Kategorien anbieten.
            leafCategories = all
                .filter { category in
                    !all.contains { $0.parentID == category.id }
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            tags = try await tagsTask
            compiledRules = CategoryRuleEngine().compile(
                try await dependencies.ruleRepository.rules(),
                assignableCategoryIDs: Set(leafCategories.map(\.id))
            )
            if draft.accountID == nil {
                draft.accountID = accounts.first?.id
            }
        } catch {
            errorMessage = String(localized: "Stammdaten konnten nicht geladen werden.")
        }
    }

    func toggleTag(_ tagID: UUID) {
        if let index = draft.tagIDs.firstIndex(of: tagID) {
            draft.tagIDs.remove(at: index)
        } else {
            draft.tagIDs.append(tagID)
        }
    }

    /// Validiert und speichert. Liefert true bei Erfolg.
    func save() async -> Bool {
        guard !isSaving, !didSave else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        guard let amount = DecimalParser.parse(draft.amountText), amount > 0 else {
            errorMessage = String(localized: "Bitte einen gültigen positiven Betrag eingeben.")
            return false
        }
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let persistedNote = note.isEmpty ? nil : note

        if draft.kind == .transfer {
            return await saveTransferPair(
                amount: amount,
                date: draft.date,
                note: persistedNote,
                tagIDs: draft.tagIDs
            )
        }

        let merchant = draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !merchant.isEmpty else {
            errorMessage = String(localized: "Bitte einen Händler bzw. eine Beschreibung eingeben.")
            return false
        }
        guard let accountID = draft.accountID,
              let account = accounts.first(where: { $0.id == accountID }) else {
            errorMessage = String(localized: "Bitte ein Konto wählen.")
            return false
        }

        let signedAmount: Decimal
        let kind: TransactionKind
        switch draft.kind {
        case .expense:
            signedAmount = -amount
            kind = .purchase
        case .income:
            signedAmount = amount
            kind = .income
        case .transfer:
            return false
        }

        if let editing {
            return await saveEdit(
                of: editing,
                accountID: accountID,
                currency: account.currency,
                kind: kind,
                signedAmount: signedAmount,
                merchant: merchant,
                note: persistedNote
            )
        }

        let transaction = Transaction(
            id: primaryTransactionID,
            accountID: accountID,
            source: .manual,
            externalID: manualExternalID,
            status: .booked,
            kind: kind,
            amount: Money(amount: signedAmount, currency: account.currency),
            bookedAt: draft.date,
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant,
            categoryID: draft.categoryID ?? suggestedCategory?.id,
            note: persistedNote,
            tagIDs: draft.tagIDs
        )

        do {
            try await dependencies.transactionRepository.upsert([transaction])
            if !draft.tagIDs.isEmpty || !(transaction.note ?? "").isEmpty {
                // Roadmap #62-Regel: User-Metadaten gehören in die Annotation.
                let annotation = TransactionAnnotation.legacyFallback(for: transaction)
                try await dependencies.transactionAnnotationRepository.upsert([annotation])
            }
            didSave = true
            dependencies.changeTracker.markChanged()
            return true
        } catch {
            errorMessage = String(localized: "Transaktion konnte nicht gespeichert werden.")
            return false
        }
    }

    /// Schreibt die Änderungen in die bestehende Buchung: ID, externalID,
    /// Quelle und Anlagezeitpunkt bleiben, damit Verknüpfungen (Belege,
    /// Sammlungen, Anteile) erhalten bleiben. Notiz/Tags gehen in die
    /// Annotation, ohne Prüf- oder Ausschluss-Status zu verlieren.
    private func saveEdit(
        of original: Transaction,
        accountID: UUID,
        currency: CurrencyCode,
        kind: TransactionKind,
        signedAmount: Decimal,
        merchant: String,
        note: String?
    ) async -> Bool {
        do {
            var updated = try await dependencies.transactionRepository.transaction(id: original.id) ?? original
            updated.accountID = accountID
            updated.kind = kind
            updated.amount = Money(amount: signedAmount, currency: currency)
            updated.bookedAt = draft.date
            updated.rawDescription = merchant
            updated.rawMerchantName = merchant
            updated.merchantDisplayName = merchant
            updated.categoryID = draft.categoryID
            updated.note = note
            updated.tagIDs = draft.tagIDs
            updated.updatedAt = Date()
            try await dependencies.transactionRepository.upsert([updated])

            let existing = try await dependencies.transactionAnnotationRepository.annotation(transactionID: original.id)
            if var annotation = existing {
                annotation.note = note
                annotation.tagIDs = draft.tagIDs
                annotation.updatedAt = Date()
                try await dependencies.transactionAnnotationRepository.upsert([annotation])
            } else if note != nil || !draft.tagIDs.isEmpty {
                try await dependencies.transactionAnnotationRepository.upsert([.legacyFallback(for: updated)])
            }
            didSave = true
            dependencies.changeTracker.markChanged()
            return true
        } catch {
            errorMessage = String(localized: "Änderungen konnten nicht gespeichert werden.")
            return false
        }
    }

    /// Transfer-Paar (#74): Abbuchung auf From-Konto + Gutschrift auf
    /// To-Konto, beide kind .transfer (Cashflow-neutral), gemeinsame
    /// externalID-Basis als Pair-Link.
    private func saveTransferPair(
        amount: Decimal,
        date: Date,
        note: String?,
        tagIDs: [UUID]
    ) async -> Bool {
        guard let fromID = transferDraft.fromAccountID,
              let fromAccount = accounts.first(where: { $0.id == fromID }) else {
            errorMessage = String(localized: "Bitte das Ausgangskonto (Von) wählen.")
            return false
        }
        guard let toID = transferDraft.toAccountID,
              let toAccount = accounts.first(where: { $0.id == toID }) else {
            errorMessage = String(localized: "Bitte das Zielkonto (Nach) wählen.")
            return false
        }
        guard fromID != toID else {
            errorMessage = String(localized: "Ausgangs- und Zielkonto müssen unterschiedlich sein.")
            return false
        }
        guard fromAccount.currency == toAccount.currency else {
            errorMessage = String(localized: "Transfers zwischen unterschiedlichen Währungen benötigen eine explizite Umrechnung.")
            return false
        }

        let groupBase = "\(manualExternalID)-transfer"
        let merchant = "Transfer"

        func makeTxn(id: UUID, accountID: UUID, signed: Decimal, suffix: String) -> Transaction {
            Transaction(
                id: id,
                accountID: accountID,
                source: .manual,
                externalID: "\(groupBase):\(suffix)",
                status: .booked,
                kind: .transfer,
                amount: Money(amount: signed, currency: fromAccount.currency),
                bookedAt: date,
                rawDescription: merchant,
                rawMerchantName: merchant,
                merchantDisplayName: merchant,
                note: note,
                tagIDs: tagIDs
            )
        }

        let outgoing = makeTxn(id: primaryTransactionID, accountID: fromID, signed: -amount, suffix: "from")
        let incoming = makeTxn(id: transferCounterpartID, accountID: toID, signed: amount, suffix: "to")

        do {
            try await dependencies.transactionRepository.upsert([outgoing, incoming])
            if !tagIDs.isEmpty || note != nil {
                try await dependencies.transactionAnnotationRepository.upsert([
                    .legacyFallback(for: outgoing),
                    .legacyFallback(for: incoming)
                ])
            }
            didSave = true
            dependencies.changeTracker.markChanged()
            return true
        } catch {
            errorMessage = String(localized: "Transfer konnte nicht gespeichert werden.")
            return false
        }
    }
}
