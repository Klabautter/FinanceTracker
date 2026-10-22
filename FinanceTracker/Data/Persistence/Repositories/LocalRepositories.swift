import Foundation
import SwiftData

final class LocalTransactionRepository: TransactionRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func transactionPage(
        matching query: TransactionQuery,
        sort: TransactionSortOrder,
        offset: Int,
        limit: Int
    ) async throws -> TransactionPage {
        let foldedNeedle = query.searchText
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)

        // WP21: Sort-Case → Store-Deskriptoren (DB-seitige globale Sortierung).
        let merchantSort: Bool? = {
            switch sort {
            case .merchantAscending: true
            case .merchantDescending: false
            default: nil
            }
        }()
        let amountSort: Bool? = {
            switch sort {
            case .amountAscending: true
            case .amountDescending: false
            default: nil
            }
        }()

        // WP20 (§138): Signpost für den Transaction-Page-Hot-Path
        // (Search/Paging), nur Name/Dauer, keine Nutzdaten.
        return try await PerfSignpost.measure("TransactionSearch") {
            try await persistence.loadTransactionPage(
                intervalStart: query.dateInterval?.start,
                intervalEnd: query.dateInterval?.end,
                searchText: foldedNeedle,
                accountIDs: query.accountIDs,
                sourceRaws: Set(query.sources.map(\.rawValue)),
                statusRaws: Set(query.statuses.map(\.rawValue)),
                categoryIDs: query.categoryIDs,
                tagIDs: query.tagIDs,
                tagMatchMode: query.tagMatchMode,
                merchantSort: merchantSort,
                amountSort: amountSort,
                ascending: sort == .dateAscending,
                offset: offset,
                limit: limit
            )
        }
    }

    func recentTransactions(limit: Int) async throws -> [Transaction] {
        try await persistence.loadRecentTransactions(limit: limit)
    }

    func transactions(matching query: TransactionQuery) async throws -> [Transaction] {
        // WP19/WP9: Tag-Pushdown über die Join-Tabelle (ANY=Union,
        // ALL=Intersection), dann in-memory Intersect (Korrektheitsnetz).
        let taggedIDs: Set<UUID> = query.tagIDs.isEmpty
            ? []
            : (try await persistence.loadTransactionIDs(tagIDs: query.tagIDs, mode: query.tagMatchMode))

        if let interval = query.dateInterval {
            // Query-Pushdown (Roadmap #179): Datum, Konten und Quelle werden
            // in der DB gefiltert; matches() hält die Ergebnis-Korrektheit.
            let sourceRaw: String? = query.sources.count == 1 ? query.sources.first?.rawValue : nil
            let fetched: [Transaction]
            switch query.accountIDs.count {
            case 0 where sourceRaw != nil:
                fetched = try await persistence.loadTransactionsBySource(
                    intervalStart: interval.start,
                    intervalEnd: interval.end,
                    sourceRaw: sourceRaw!
                )
            case 0:
                fetched = try await persistence.loadTransactions(
                    intervalStart: interval.start,
                    intervalEnd: interval.end
                )
            case 1:
                fetched = try await persistence.loadTransactionsByAccount(
                    intervalStart: interval.start,
                    intervalEnd: interval.end,
                    accountID: query.accountIDs.first!,
                    sourceRaw: sourceRaw
                )
            default:
                if let sourceRaw {
                    fetched = try await persistence.loadTransactionsByAccountsAndSource(
                        intervalStart: interval.start,
                        intervalEnd: interval.end,
                        accountIDs: query.accountIDs,
                        sourceRaw: sourceRaw
                    )
                } else {
                    fetched = try await persistence.loadTransactionsByAccounts(
                        intervalStart: interval.start,
                        intervalEnd: interval.end,
                        accountIDs: query.accountIDs
                    )
                }
            }
            let scoped = taggedIDs.isEmpty ? fetched : fetched.filter { taggedIDs.contains($0.id) }
            return try await matchingCategories(scoped, query: query)
        }

        let all = try await persistence.loadAllTransactions()
        let scoped = taggedIDs.isEmpty ? all : all.filter { taggedIDs.contains($0.id) }
        var refinement = query
        refinement.categoryIDs = []
        return refinement.refining(try await matchingCategories(scoped, query: query))
    }

    private func matchingCategories(_ transactions: [Transaction], query: TransactionQuery) async throws -> [Transaction] {
        var remainingQuery = query
        remainingQuery.categoryIDs = []
        let candidates = transactions.filter(remainingQuery.matches)
        guard !query.categoryIDs.isEmpty else { return candidates }
        let lines = try await persistence.loadSplitLines(parentTransactionIDs: Set(candidates.map(\.id)))
        let selectedIDs = Set(TransactionCategoryScope.projectingAmounts(
            transactions: candidates, splitLines: lines, categoryIDs: query.categoryIDs
        ).map(\.id))
        // Repositories return original facts; amount projection belongs to analytics.
        return candidates.filter { selectedIDs.contains($0.id) }
    }

    func transactions(accountID: UUID, source: TransactionSource) async throws -> [Transaction] {
        try await persistence.loadTransactions(accountID: accountID, sourceRaw: source.rawValue)
    }

    /// WP13/WP14 (§98): Leichte Review-Projection, propertiesToFetch-Pfad.
    func reviewCandidateTransactions() async throws -> [Transaction] {
        try await persistence.loadReviewCandidateTransactions()
    }

    func transactions(ids: Set<UUID>) async throws -> [Transaction] {
        try await persistence.loadTransactions(ids: ids)
    }

    func assignCategoriesToUncategorized(
        matching rules: [CategoryRule],
        assignableCategoryIDs: Set<Category.ID>
    ) async throws -> Set<UUID> {
        try await persistence.assignCategoriesToUncategorized(
            matching: rules,
            assignableCategoryIDs: assignableCategoryIDs
        )
    }

    func accountMovementRows() async throws -> [AccountMovementRow] {
        try await persistence.loadAccountMovementRows()
    }

    func transaction(id: UUID) async throws -> Transaction? {
        try await persistence.loadTransaction(id: id)
    }

    func upsert(_ transactions: [Transaction]) async throws {
        try await persistence.upsertTransactions(transactions)
    }

    func deleteTransactions(importBatchID: UUID) async throws {
        try await persistence.deleteTransactions(importBatchID: importBatchID)
    }

    func deleteTransactions(ids: Set<UUID>) async throws {
        try await persistence.deleteTransactions(ids: ids)
    }

    func count() async throws -> Int {
        try await persistence.countTransactions()
    }

    func deleteAll() async throws {
        try await persistence.deleteAllTransactions()
    }

    func deleteAllDemoTransactions() async throws {
        try await persistence.deleteAllDemoTransactions()
    }
}

final class LocalTransactionAnnotationRepository: TransactionAnnotationRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func annotations(transactionIDs: Set<UUID>) async throws -> [TransactionAnnotation] {
        try await persistence.loadTransactionAnnotations(transactionIDs: transactionIDs)
    }

    func annotation(transactionID: UUID) async throws -> TransactionAnnotation? {
        try await persistence.loadTransactionAnnotation(transactionID: transactionID)
    }

    func upsert(_ annotations: [TransactionAnnotation]) async throws {
        try await persistence.upsertTransactionAnnotations(annotations)
    }

    func delete(transactionID: UUID) async throws {
        try await persistence.deleteTransactionAnnotation(transactionID: transactionID)
    }

    func deleteAll() async throws {
        try await persistence.deleteAllTransactionAnnotations()
    }
}

final class LocalTransactionCollectionRepository: TransactionCollectionRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func collections() async throws -> [TransactionCollection] {
        try await persistence.loadTransactionCollections().sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt < $1.createdAt
        }
    }

    func collection(id: UUID) async throws -> TransactionCollection? {
        try await persistence.loadTransactionCollection(id: id)
    }

    func upsert(_ collections: [TransactionCollection]) async throws {
        try await persistence.upsertTransactionCollections(collections)
    }

    func delete(id: UUID) async throws {
        try await persistence.deleteTransactionCollection(id: id)
    }

    func deleteAll() async throws {
        try await persistence.deleteAllTransactionCollections()
    }
}

final class LocalTransactionCollectionOverrideRepository: TransactionCollectionOverrideRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func overrides(collectionID: UUID) async throws -> [TransactionCollectionOverride] {
        try await persistence.loadTransactionCollectionOverrides(collectionID: collectionID)
    }

    func allOverrides() async throws -> [TransactionCollectionOverride] {
        try await persistence.loadAllTransactionCollectionOverrides()
    }

    func override(
        collectionID: UUID,
        transactionID: UUID
    ) async throws -> TransactionCollectionOverride? {
        try await persistence.loadTransactionCollectionOverride(
            collectionID: collectionID,
            transactionID: transactionID
        )
    }

    func upsert(_ overrides: [TransactionCollectionOverride]) async throws {
        try await persistence.upsertTransactionCollectionOverrides(overrides)
    }

    func delete(collectionID: UUID, transactionID: UUID) async throws {
        try await persistence.deleteTransactionCollectionOverride(
            collectionID: collectionID,
            transactionID: transactionID
        )
    }

    func deleteAll(collectionID: UUID) async throws {
        try await persistence.deleteTransactionCollectionOverrides(collectionID: collectionID)
    }

    func deleteAll() async throws {
        try await persistence.deleteAllTransactionCollectionOverrides()
    }
}

final class LocalAccountRepository: AccountRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func accounts() async throws -> [Account] {
        let all = try await persistence.loadAccounts()
        return all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func account(id: UUID) async throws -> Account? {
        try await persistence.loadAccount(id: id)
    }

    func account(providerAccountID: String, connectionID: UUID) async throws -> Account? {
        try await persistence.loadAccount(providerAccountID: providerAccountID, connectionID: connectionID)
    }

    func upsert(_ accounts: [Account]) async throws {
        try await persistence.upsertAccounts(accounts)
    }

    func deleteAll() async throws {
        try await persistence.deleteAllAccounts()
    }

    func deleteAccountWithTransactions(id: UUID) async throws {
        try await persistence.deleteAccountWithTransactions(accountID: id)
    }

    func deleteAllDemoAccounts() async throws {
        try await persistence.deleteAllDemoAccounts()
    }
}

final class LocalCategoryRepository: CategoryRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func categories() async throws -> [Category] {
        let all = try await persistence.loadCategories()
        return all.sorted {
            if let aParent = $0.parentID, let bParent = $1.parentID {
                return aParent.uuidString < bParent.uuidString
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func category(id: UUID) async throws -> Category? {
        try await persistence.loadCategory(id: id)
    }

    func usageCounts() async throws -> [UUID: Int] {
        try await persistence.loadCategoryUsageCounts()
    }

    func upsert(_ categories: [Category]) async throws {
        try await persistence.upsertCategories(categories)
    }

    func deleteAll() async throws {
        try await persistence.deleteAllCategories()
    }

    func delete(id: UUID, reassignTo newCategoryID: UUID?) async throws {
        try await persistence.deleteCategory(id: id, reassignTo: newCategoryID)
    }

}

final class LocalMerchantRepository: MerchantRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func merchants() async throws -> [Merchant] {
        let all = try await persistence.loadMerchants()
        return all.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func merchant(id: UUID) async throws -> Merchant? {
        try await persistence.loadMerchant(id: id)
    }

    func upsert(_ merchants: [Merchant]) async throws {
        try await persistence.upsertMerchants(merchants)
    }

    func deleteAll() async throws {
        try await persistence.deleteAllMerchants()
    }
}

final class LocalCategoryRuleRepository: CategoryRuleRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func rules() async throws -> [CategoryRule] {
        try await persistence.loadRules()
    }

    func rule(id: UUID) async throws -> CategoryRule? {
        try await persistence.loadRule(id: id)
    }

    func upsert(_ rules: [CategoryRule]) async throws {
        try await persistence.upsertRules(rules)
    }

    func delete(id: UUID) async throws {
        try await persistence.deleteRule(id: id)
    }
}

final class LocalImportBatchRepository: ImportBatchRepository {
    private let persistence: PersistenceModelActor

    #if DEBUG
    private let failureInjector = CommitFailureInjector()
    #endif

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    #if DEBUG
    func _testInjectCommitFailure(_ error: any Error) {
        failureInjector.set(error)
    }
    #endif

    func batches() async throws -> [ImportBatch] {
        let all = try await persistence.loadImportBatches()
        return all.sorted { $0.completedAt > $1.completedAt }
    }

    func latestBatch() async throws -> ImportBatch? {
        try await persistence.loadLatestImportBatch()
    }

    func batch(id: UUID) async throws -> ImportBatch? {
        try await persistence.loadImportBatches().first { $0.id == id }
    }

    func upsert(_ batches: [ImportBatch]) async throws {
        try await persistence.upsertImportBatches(batches)
    }

    func delete(id: UUID) async throws {
        try await persistence.deleteImportBatch(id: id)
    }

    func deleteAll() async throws {
        try await persistence.deleteAllImportBatches()
    }

    func commitImport(batch: ImportBatch, inserts: [Transaction], updates: [Transaction]) async throws {
        #if DEBUG
        if let injected = failureInjector.current {
            throw injected
        }
        #endif
        try await persistence.commitImportBatch(batch: batch, inserts: inserts, updates: updates)
    }

    func rollbackImportBatch(id: UUID) async throws {
        try await persistence.rollbackImportBatch(id: id)
    }
}


#if DEBUG
final class CommitFailureInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var error: (any Error)?

    func set(_ newError: any Error) {
        lock.lock()
        defer { lock.unlock() }
        error = newError
    }

    var current: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}
#endif


final class LocalConnectionRepository: ConnectionRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func connections() async throws -> [Connection] {
        let all = try await persistence.loadConnections()
        return all.sorted { $0.createdAt < $1.createdAt }
    }

    func connection(id: UUID) async throws -> Connection? {
        try await persistence.loadConnection(id: id)
    }

    func connection(providerConnectionID: String) async throws -> Connection? {
        try await persistence.loadConnection(providerConnectionID: providerConnectionID)
    }

    func upsert(_ connections: [Connection]) async throws {
        try await persistence.upsertConnections(connections)
    }

    func delete(id: UUID) async throws {
        try await persistence.deleteConnection(id: id)
    }

    func deleteAll() async throws {
        try await persistence.deleteAllConnections()
    }
}


final class LocalBudgetRepository: BudgetRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func budgets() async throws -> [Budget] {
        try await persistence.loadBudgets()
    }

    func budget(id: UUID) async throws -> Budget? {
        try await persistence.loadBudget(id: id)
    }

    func upsert(_ budgets: [Budget]) async throws {
        try await persistence.upsertBudgets(budgets)
        // Roadmap #99: Gültigen Betrag für den aktuellen Monat historisieren
        // (idempotent: der Eintrag wird bei erneuter Änderung im selben
        // Monat überschrieben; vergangene Monate bleiben unverändert).
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        for budget in budgets {
            try await upsertAmountHistory(BudgetAmountHistory(
                budgetID: budget.id,
                periodStart: monthStart,
                amount: budget.amount,
                currency: budget.currency
            ))
        }
    }

    func delete(id: UUID) async throws {
        try await persistence.deleteBudget2(id: id)
        try await persistence.deleteBudget(id: id)
    }

    func deleteAll() async throws {
        try await persistence.deleteAllBudgets()
    }

    func amountHistory(budgetID: UUID?) async throws -> [BudgetAmountHistory] {
        try await persistence.loadBudgetAmountHistory(budgetID: budgetID)
    }

    func upsertAmountHistory(_ entry: BudgetAmountHistory) async throws {
        try await persistence.upsertBudgetAmountHistory(entry)
    }
}


final class LocalTransactionSplitRepository: TransactionSplitRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func allSplitLines() async throws -> [TransactionSplitLine] {
        try await persistence.loadAllSplitLines()
    }

    func splitLines(parentTransactionID: UUID) async throws -> [TransactionSplitLine] {
        try await persistence.loadSplitLines(parentTransactionID: parentTransactionID)
    }

    func splitLines(parentTransactionIDs: Set<UUID>) async throws -> [TransactionSplitLine] {
        try await persistence.loadSplitLines(parentTransactionIDs: parentTransactionIDs)
    }

    func upsert(_ lines: [TransactionSplitLine]) async throws {
        try await persistence.upsertSplitLines(lines)
    }

    func deleteAll() async throws {
        try await persistence.deleteAllSplitLines()
    }

    func deleteAll(parentTransactionID: UUID) async throws {
        try await persistence.deleteSplitLines(parentTransactionID: parentTransactionID)
    }
}

final class LocalSharedExpenseShareRepository: SharedExpenseShareRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func allShares() async throws -> [SharedExpenseShare] {
        try await persistence.loadAllSharedExpenseShares()
    }

    func shares(transactionID: UUID) async throws -> [SharedExpenseShare] {
        try await persistence.loadSharedExpenseShares(transactionID: transactionID)
    }

    func shares(transactionIDs: Set<UUID>) async throws -> [SharedExpenseShare] {
        try await persistence.loadSharedExpenseShares(transactionIDs: transactionIDs)
    }

    func share(id: UUID) async throws -> SharedExpenseShare? {
        try await persistence.loadSharedExpenseShare(id: id)
    }

    func upsert(_ shares: [SharedExpenseShare]) async throws {
        try await persistence.upsertSharedExpenseShares(shares)
    }

    func delete(id: UUID) async throws {
        try await persistence.deleteSharedExpenseShare(id: id)
    }

    func deleteAll(transactionID: UUID) async throws {
        try await persistence.deleteSharedExpenseShares(transactionID: transactionID)
    }

    func deleteAll() async throws {
        try await persistence.deleteAllSharedExpenseShares()
    }
}

final class LocalRecurringCommitmentRepository: RecurringCommitmentRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func commitments() async throws -> [RecurringCommitment] {
        try await persistence.loadRecurringCommitments()
            .sorted { $0.nextExpectedDate ?? .distantFuture < $1.nextExpectedDate ?? .distantFuture }
    }

    func commitment(id: UUID) async throws -> RecurringCommitment? {
        try await persistence.loadRecurringCommitment(id: id)
    }

    func upsert(_ commitments: [RecurringCommitment]) async throws {
        try await persistence.upsertRecurringCommitments(commitments)
    }

    func delete(id: UUID) async throws {
        try await persistence.deleteRecurringCommitment(id: id)
    }

    func deleteAll() async throws {
        try await persistence.deleteAllRecurringCommitments()
    }

    func occurrences(commitmentID: UUID) async throws -> [RecurringOccurrence] {
        try await persistence.loadRecurringOccurrences(commitmentID: commitmentID)
    }

    func allOccurrences() async throws -> [RecurringOccurrence] {
        try await persistence.loadAllRecurringOccurrences()
    }

    func addOccurrence(_ occurrence: RecurringOccurrence) async throws {
        try await persistence.addRecurringOccurrence(occurrence)
    }

    func removeOccurrence(id: UUID) async throws {
        try await persistence.deleteRecurringOccurrence(id: id)
    }
}

final class LocalTransactionAttachmentRepository: TransactionAttachmentRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func attachments(transactionID: UUID) async throws -> [TransactionAttachment] {
        try await persistence.loadTransactionAttachments(transactionID: transactionID)
    }

    func allAttachments() async throws -> [TransactionAttachment] {
        try await persistence.loadAllTransactionAttachments()
    }

    func add(_ attachment: TransactionAttachment) async throws {
        try await persistence.addTransactionAttachment(attachment)
    }

    func delete(id: UUID) async throws {
        try await persistence.deleteTransactionAttachment(id: id)
    }

    func deleteAll() async throws {
        try await persistence.deleteAllTransactionAttachments()
    }
}

final class LocalTagRepository: TagRepository {
    private let persistence: PersistenceModelActor

    init(modelContainer: ModelContainer) {
        self.persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    func tags() async throws -> [Tag] {
        let all = try await persistence.loadTags()
        return all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func upsert(_ tags: [Tag]) async throws {
        try await persistence.upsertTags(tags)
    }

    func delete(id: UUID) async throws {
        try await persistence.deleteTag(id: id)
    }

    func usageCounts() async throws -> [UUID: Int] {
        // WP19: Einmaliger Backfill der Join-Rows für Bestände, dann Pushdown.
        try await persistence.ensureTagJoinBackfill()
        return try await persistence.loadTagUsageCounts()
    }

    func deleteAll() async throws {
        try await persistence.deleteAllTags()
    }
}
