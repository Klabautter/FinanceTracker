import Foundation

struct TransactionPage: Sendable, Equatable {
    let transactions: [Transaction]
    let hasMore: Bool
}

protocol TransactionRepository: Sendable {
    func transactionPage(
        matching query: TransactionQuery,
        sort: TransactionSortOrder,
        offset: Int,
        limit: Int
    ) async throws -> TransactionPage
    func transactions(matching query: TransactionQuery) async throws -> [Transaction]
    func transactions(accountID: UUID, source: TransactionSource) async throws -> [Transaction]
    func recentTransactions(limit: Int) async throws -> [Transaction]
    func transaction(id: UUID) async throws -> Transaction?
    func upsert(_ transactions: [Transaction]) async throws
    func deleteTransactions(importBatchID: UUID) async throws
    /// Entfernt einzelne Buchungen samt abhängiger Zeilen (atomar).
    func deleteTransactions(ids: Set<UUID>) async throws
    func count() async throws -> Int
    func deleteAll() async throws

    /// WP-UX: Demo-Seed-Transaktionen (Source = demo) entfernen.
    func deleteAllDemoTransactions() async throws

    /// WP13/WP14 (§98/§103): Leichte Review-Projection (globale Kandidaten
    /// ohne Full-Domain-Hydration). Persistente Implementierungen
    /// überschreiben mit einem propertiesToFetch-basierten Pfad; der
    /// Default fällt auf den vollen Load zurück.
    func reviewCandidateTransactions() async throws -> [Transaction]

    /// MacUX-Automatisierung (System-Katalog-Rückfill): Batch-Ladung nach
    /// IDs. Persistente Implementierungen überschreiben mit ID-Pushdown;
    /// der Default filtert einen vollen Load (korrekt, aber unperformant).
    func transactions(ids: Set<UUID>) async throws -> [Transaction]

    /// Wendet eine bestätigte Lernregel ausschließlich auf bislang
    /// unkategorisierte Bestandsbuchungen an und liefert die geänderten IDs.
    func assignCategoriesToUncategorized(
        matching rules: [CategoryRule],
        assignableCategoryIDs: Set<Category.ID>
    ) async throws -> Set<UUID>
}

extension TransactionRepository {
    /// WP13/WP14 (§98/§103): Leichte Review-Projection (globale Kandidaten
    /// ohne Full-Domain-Hydration). Persistente Implementierungen
    /// überschreiben mit einem propertiesToFetch-basierten Pfad; der
    /// Default fällt auf den vollen Load zurück.
    func reviewCandidateTransactions() async throws -> [Transaction] {
        try await transactions(matching: TransactionQuery())
    }

    func transactions(ids: Set<UUID>) async throws -> [Transaction] {
        guard !ids.isEmpty else { return [] }
        let all = try await transactions(matching: TransactionQuery())
        return all.filter { ids.contains($0.id) }
    }

    func assignCategoriesToUncategorized(
        matching rules: [CategoryRule],
        assignableCategoryIDs: Set<Category.ID>
    ) async throws -> Set<UUID> {
        let compiledRules = CategoryRuleEngine().compile(
            rules,
            assignableCategoryIDs: assignableCategoryIDs
        )
        var updates: [Transaction] = []
        for var transaction in try await transactions(matching: TransactionQuery()) where transaction.categoryID == nil {
            if compiledRules.apply(to: &transaction) {
                transaction.updatedAt = Date()
                updates.append(transaction)
            }
        }
        try await upsert(updates)
        return Set(updates.map(\.id))
    }

    /// Optionale Optimierung (Roadmap #179): Schlanke Bewegungszeilen für
    /// Konto-Aggregationen. Standard-Fallback: vollständige Hydratation.
    /// Persistente Implementierungen überschreiben dies mit einem
    /// propertiesToFetch-basierten schnellen Pfad.
    func accountMovementRows() async throws -> [AccountMovementRow] {
        let all = try await transactions(matching: TransactionQuery())
        return all.map { txn in
            AccountMovementRow(
                accountID: txn.accountID,
                amountValue: NSDecimalNumber(decimal: txn.amount.amount).stringValue,
                currencyRaw: txn.amount.currency.rawValue,
                statusRaw: txn.status.rawValue,
                date: txn.displayDate
            )
        }
    }
}

protocol TransactionAnnotationRepository: Sendable {
    func annotations(transactionIDs: Set<UUID>) async throws -> [TransactionAnnotation]
    func annotation(transactionID: UUID) async throws -> TransactionAnnotation?
    func upsert(_ annotations: [TransactionAnnotation]) async throws
    func delete(transactionID: UUID) async throws
    func deleteAll() async throws
}

protocol TransactionCollectionRepository: Sendable {
    func collections() async throws -> [TransactionCollection]
    func collection(id: UUID) async throws -> TransactionCollection?
    func upsert(_ collections: [TransactionCollection]) async throws
    /// Löscht zuerst alle Overrides der Collection.
    func delete(id: UUID) async throws
    func deleteAll() async throws
}

protocol TransactionCollectionOverrideRepository: Sendable {
    func overrides(collectionID: UUID) async throws -> [TransactionCollectionOverride]
    func allOverrides() async throws -> [TransactionCollectionOverride]
    func override(collectionID: UUID, transactionID: UUID) async throws -> TransactionCollectionOverride?
    func upsert(_ overrides: [TransactionCollectionOverride]) async throws
    func delete(collectionID: UUID, transactionID: UUID) async throws
    func deleteAll(collectionID: UUID) async throws
    func deleteAll() async throws
}

extension TransactionAnnotationRepository {
    /// Alle Annotationen (z. B. für Tag-Usage-Zählungen).
    func annotations() async throws -> [TransactionAnnotation] {
        try await annotations(transactionIDs: [])
    }
}

protocol TransactionSplitRepository: Sendable {
    func allSplitLines() async throws -> [TransactionSplitLine]
    func deleteAll() async throws
    func splitLines(parentTransactionID: UUID) async throws -> [TransactionSplitLine]
    func splitLines(parentTransactionIDs: Set<UUID>) async throws -> [TransactionSplitLine]
    func upsert(_ lines: [TransactionSplitLine]) async throws
    func deleteAll(parentTransactionID: UUID) async throws
}

/// P2 Gruppenanteile (Splitwise-light, V12, #27/#11): User-Sidecar zu
/// Transaktionen: die Transaktion bleibt Provider-Fakt, nur die
/// Aufteilung ist User-Besitz. Ausgleich erfolgt ausschließlich als
/// manuelle Transfer-Buchung (kein PIS, #15), neutral für Cashflow (#28).
protocol SharedExpenseShareRepository: Sendable {
    func allShares() async throws -> [SharedExpenseShare]
    func shares(transactionID: UUID) async throws -> [SharedExpenseShare]
    func shares(transactionIDs: Set<UUID>) async throws -> [SharedExpenseShare]
    func share(id: UUID) async throws -> SharedExpenseShare?
    func upsert(_ shares: [SharedExpenseShare]) async throws
    func delete(id: UUID) async throws
    func deleteAll(transactionID: UUID) async throws
    func deleteAll() async throws
}

protocol RecurringCommitmentRepository: Sendable {
    func commitments() async throws -> [RecurringCommitment]
    func commitment(id: UUID) async throws -> RecurringCommitment?
    func upsert(_ commitments: [RecurringCommitment]) async throws
    func delete(id: UUID) async throws
    func deleteAll() async throws

    func occurrences(commitmentID: UUID) async throws -> [RecurringOccurrence]
    func allOccurrences() async throws -> [RecurringOccurrence]
    func addOccurrence(_ occurrence: RecurringOccurrence) async throws
    func removeOccurrence(id: UUID) async throws
}

protocol TransactionAttachmentRepository: Sendable {
    func attachments(transactionID: UUID) async throws -> [TransactionAttachment]
    /// WP29: Alle Attachment-Metadaten (für vollständiges Backup).
    func allAttachments() async throws -> [TransactionAttachment]
    func add(_ attachment: TransactionAttachment) async throws
    func delete(id: UUID) async throws
    /// WP2 (§14): Alle Attachment-Metadaten entfernen (Dateien orchestriert
    /// der Aufrufer, damit Dateisystem + Metadaten konsistent bleiben).
    func deleteAll() async throws
}

protocol AccountRepository: Sendable {
    func accounts() async throws -> [Account]
    func account(id: UUID) async throws -> Account?
    func account(providerAccountID: String, connectionID: UUID) async throws -> Account?
    func upsert(_ accounts: [Account]) async throws
    func deleteAll() async throws

    /// Entfernt ein Konto zusammen mit allen seinen Buchungen (atomar).
    func deleteAccountWithTransactions(id: UUID) async throws

    /// WP-UX: Demo-Seed-Konten (Source = demo) entfernen.
    func deleteAllDemoAccounts() async throws
}

protocol CategoryRepository: Sendable {
    func categories() async throws -> [Category]
    func category(id: UUID) async throws -> Category?
    func upsert(_ categories: [Category]) async throws
    func deleteAll() async throws

    /// WP20/§145: Nutzungsanzahl pro Kategorie, Pushdown, kein Full-Domain-Load.
    func usageCounts() async throws -> [UUID: Int]

    /// Löscht eine Kategorie und weist ihre Transaktionen neu zu
    /// (nil = „Ohne Kategorie“). Roadmap #50.
    func delete(id: UUID, reassignTo newCategoryID: UUID?) async throws
}

protocol MerchantRepository: Sendable {
    func merchants() async throws -> [Merchant]
    func merchant(id: UUID) async throws -> Merchant?
    func upsert(_ merchants: [Merchant]) async throws
    func deleteAll() async throws
}

protocol CategoryRuleRepository: Sendable {
    func rules() async throws -> [CategoryRule]
    func rule(id: UUID) async throws -> CategoryRule?
    func upsert(_ rules: [CategoryRule]) async throws
    func delete(id: UUID) async throws
}

protocol ConnectionRepository: Sendable {
    func connections() async throws -> [Connection]
    func connection(id: UUID) async throws -> Connection?
    func connection(providerConnectionID: String) async throws -> Connection?
    func upsert(_ connections: [Connection]) async throws
    func delete(id: UUID) async throws
    /// WP2 (§14): Alle Connections entfernen (nicht die Keychain-Credentials).
    func deleteAll() async throws
}

protocol BudgetRepository: Sendable {
    func budgets() async throws -> [Budget]
    func budget(id: UUID) async throws -> Budget?
    func upsert(_ budgets: [Budget]) async throws
    func delete(id: UUID) async throws
    func deleteAll() async throws

    func amountHistory(budgetID: UUID?) async throws -> [BudgetAmountHistory]
    func upsertAmountHistory(_ entry: BudgetAmountHistory) async throws
}

protocol TagRepository: Sendable {
    func tags() async throws -> [Tag]
    func upsert(_ tags: [Tag]) async throws
    func delete(id: UUID) async throws
    /// WP19: Nutzungsanzahl pro Tag per Join-Row-Pushdown.
    func usageCounts() async throws -> [UUID: Int]
    /// WP2 (§14): Tag-Join-Rows + Tags entfernen (§15: Joins zuerst).
    func deleteAll() async throws
}
