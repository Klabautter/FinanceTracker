import Foundation
import Testing

@testable import FinanceTracker

struct FailingTransactionRepository: TransactionRepository {
    enum Failure: Error { case injected }

    let base: TransactionRepository

    func transactions(matching query: TransactionQuery) async throws -> [Transaction] {
        try await base.transactions(matching: query)
    }

    func transactions(accountID: UUID, source: TransactionSource) async throws -> [Transaction] {
        try await base.transactions(accountID: accountID, source: source)
    }

    func recentTransactions(limit: Int) async throws -> [Transaction] {
        try await base.recentTransactions(limit: limit)
    }

    func transactionPage(matching query: TransactionQuery, sort: TransactionSortOrder, offset: Int, limit: Int) async throws -> TransactionPage {
        try await base.transactionPage(matching: query, sort: sort, offset: offset, limit: limit)
    }

    func transaction(id: UUID) async throws -> Transaction? {
        try await base.transaction(id: id)
    }

    func upsert(_ transactions: [Transaction]) async throws {
        throw Failure.injected
    }

    func deleteTransactions(importBatchID: UUID) async throws {
        try await base.deleteTransactions(importBatchID: importBatchID)
    }

    func deleteTransactions(ids: Set<UUID>) async throws {
        try await base.deleteTransactions(ids: ids)
    }

    func count() async throws -> Int {
        try await base.count()
    }

    func deleteAllDemoTransactions() async throws {
        throw BankProviderError.missingCredentials
    }

    func deleteAll() async throws {
        try await base.deleteAll()
    }
}

@MainActor
@Suite("ReviewQueueErrorHandling")
struct ReviewQueueErrorHandlingTests {
    private func makeDependencies(failUpsert: Bool) throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        var dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        if failUpsert {
            let failing = FailingTransactionRepository(base: dependencies.transactionRepository)
            dependencies = AppDependencies(
                transactionRepository: failing,
                transactionAnnotationRepository: dependencies.transactionAnnotationRepository,
                transactionCollectionRepository: dependencies.transactionCollectionRepository,
                transactionCollectionOverrideRepository: dependencies.transactionCollectionOverrideRepository,
                accountRepository: dependencies.accountRepository,
                categoryRepository: dependencies.categoryRepository,
                merchantRepository: dependencies.merchantRepository,
                ruleRepository: dependencies.ruleRepository,
                importBatchRepository: dependencies.importBatchRepository,
                connectionRepository: dependencies.connectionRepository,
                budgetRepository: dependencies.budgetRepository,
                tagRepository: dependencies.tagRepository,
                transactionSplitRepository: dependencies.transactionSplitRepository,
                sharedExpenseShareRepository: dependencies.sharedExpenseShareRepository,
                recurringCommitmentRepository: dependencies.recurringCommitmentRepository,
                    transactionAttachmentRepository: dependencies.transactionAttachmentRepository,
                bankProviderFactory: dependencies.bankProviderFactory,
                importProviders: dependencies.importProviders,
                changeTracker: dependencies.changeTracker,
                baseCurrency: dependencies.baseCurrency,
                notificationScheduler: dependencies.notificationScheduler
            )
        }
        return dependencies
    }

    private func uncategorizedItem() -> Transaction {
        Transaction(
            accountID: UUID(),
            source: .openBanking,
            status: .booked,
            amount: Money(amount: -10, currency: .eur),
            bookedAt: Date(),
            rawMerchantName: "Kiosk"
        )
    }

    @Test("assignCategory Fehler: Item bleibt, Fehlermeldung gesetzt")
    func assignFailureKeepsItemAndSetsError() async throws {
        let store = try SwiftDataStore(inMemory: true)
        var dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let txn = uncategorizedItem()
        try await dependencies.transactionRepository.upsert([txn])

        // Jetzt Repo gegen Failing austauschen, Container bleibt gleich.
        let failingRepo = FailingTransactionRepository(base: dependencies.transactionRepository)
        dependencies = AppDependencies(
            transactionRepository: failingRepo,
            transactionAnnotationRepository: dependencies.transactionAnnotationRepository,
            transactionCollectionRepository: dependencies.transactionCollectionRepository,
            transactionCollectionOverrideRepository: dependencies.transactionCollectionOverrideRepository,
            accountRepository: dependencies.accountRepository,
            categoryRepository: dependencies.categoryRepository,
            merchantRepository: dependencies.merchantRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            connectionRepository: dependencies.connectionRepository,
            budgetRepository: dependencies.budgetRepository,
            tagRepository: dependencies.tagRepository,
                transactionSplitRepository: dependencies.transactionSplitRepository,
                sharedExpenseShareRepository: dependencies.sharedExpenseShareRepository,
                recurringCommitmentRepository: dependencies.recurringCommitmentRepository,
                    transactionAttachmentRepository: dependencies.transactionAttachmentRepository,
            bankProviderFactory: dependencies.bankProviderFactory,
            importProviders: dependencies.importProviders,
            changeTracker: dependencies.changeTracker,
            baseCurrency: .eur,
            notificationScheduler: dependencies.notificationScheduler
        )

        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()

        let item = try #require(model.items.first { $0.transaction.id == txn.id })
        await model.assignCategory(item, categoryID: UUID())

        #expect(model.errorMessage != nil)
        #expect(model.items.contains { $0.id == item.id })
    }

    @Test("Load-Fehler zeigt Fehler statt 'Alles geprüft'")
    func loadFailureShowsError() async throws {
        let store = try SwiftDataStore(inMemory: true)
        var dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        let brokenRepo = BrokenReadRepository()
        dependencies = AppDependencies(
            transactionRepository: brokenRepo,
            transactionAnnotationRepository: dependencies.transactionAnnotationRepository,
            transactionCollectionRepository: dependencies.transactionCollectionRepository,
            transactionCollectionOverrideRepository: dependencies.transactionCollectionOverrideRepository,
            accountRepository: dependencies.accountRepository,
            categoryRepository: dependencies.categoryRepository,
            merchantRepository: dependencies.merchantRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            connectionRepository: dependencies.connectionRepository,
            budgetRepository: dependencies.budgetRepository,
            tagRepository: dependencies.tagRepository,
                transactionSplitRepository: dependencies.transactionSplitRepository,
                sharedExpenseShareRepository: dependencies.sharedExpenseShareRepository,
                recurringCommitmentRepository: dependencies.recurringCommitmentRepository,
                    transactionAttachmentRepository: dependencies.transactionAttachmentRepository,
            bankProviderFactory: dependencies.bankProviderFactory,
            importProviders: dependencies.importProviders,
            changeTracker: dependencies.changeTracker,
            baseCurrency: .eur,
            notificationScheduler: dependencies.notificationScheduler
        )

        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()

        #expect(model.errorMessage != nil)
    }

    @Test("Geprüft persistiert Annotation und entfernt alle Gründe der Transaktion")
    func reviewedRemovesEveryItemForTransaction() async throws {
        let dependencies = try makeDependencies(failUpsert: false)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        var transaction = uncategorizedItem()
        transaction.accountID = account.id
        transaction.amount = Money(amount: -10, currency: .usd)
        try await dependencies.transactionRepository.upsert([transaction])

        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()
        let item = try #require(model.items.first { $0.transaction.id == transaction.id })
        #expect(model.items.filter { $0.transaction.id == transaction.id }.count == 2)

        await model.markReviewed(item)

        #expect(model.items.allSatisfy { $0.transaction.id != transaction.id })
        let annotation = try #require(
            await dependencies.transactionAnnotationRepository.annotation(transactionID: transaction.id)
        )
        #expect(annotation.reviewed)
    }

    @Test("Kategorie entfernt nur Ohne-Kategorie-Grund und aktualisiert weitere Gründe")
    func categoryAssignmentResolvesOnlyUncategorizedReason() async throws {
        let dependencies = try makeDependencies(failUpsert: false)
        let account = Account(name: "USD-Karte", type: .creditCard, currency: .usd, source: .manual)
        let category = FinanceTracker.Category(name: "Einkauf", systemIconName: "cart")
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.categoryRepository.upsert([category])
        var transaction = uncategorizedItem()
        transaction.accountID = account.id
        transaction.amount = Money(amount: -10, currency: .usd)
        try await dependencies.transactionRepository.upsert([transaction])

        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()
        let uncategorized = try #require(model.items.first {
            $0.transaction.id == transaction.id && $0.reason == .uncategorized
        })

        await model.assignCategory(uncategorized, categoryID: category.id)

        let remaining = model.items.filter { $0.transaction.id == transaction.id }
        #expect(remaining.count == 1)
        #expect(remaining.first?.reason == .foreignCurrency)
        #expect(remaining.first?.transaction.categoryID == category.id)
        #expect(try await dependencies.transactionRepository.transaction(id: transaction.id)?.categoryID == category.id)
    }

    @Test("Für Händler merken aktualisiert die Regel und zieht nur unkategorisierte Treffer nach")
    func rememberMerchantUpdatesRuleAndBackfillsUncategorized() async throws {
        let dependencies = try makeDependencies(failUpsert: false)
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let merchantID = UUID()

        func transaction(categoryID: UUID? = nil) -> Transaction {
            Transaction(
                accountID: account.id,
                source: .openBanking,
                status: .booked,
                amount: Money(amount: -10, currency: .eur),
                bookedAt: Date(),
                rawMerchantName: "SPAR MARKT",
                merchantID: merchantID,
                merchantDisplayName: "SPAR",
                categoryID: categoryID
            )
        }

        let selected = transaction()
        let matchingUncategorized = transaction()
        let consciouslyCategorized = transaction(categoryID: Category.restaurants.id)
        try await dependencies.transactionRepository.upsert([
            selected, matchingUncategorized, consciouslyCategorized
        ])
        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()
        let item = try #require(model.items.first {
            $0.transaction.id == selected.id && $0.reason == .uncategorized
        })
        let revisionBefore = dependencies.changeTracker.revision

        await model.assignCategory(item, categoryID: Category.groceries.id, scope: .merchant)

        #expect(try await dependencies.transactionRepository.transaction(id: selected.id)?.categoryID == Category.groceries.id)
        #expect(try await dependencies.transactionRepository.transaction(id: matchingUncategorized.id)?.categoryID == Category.groceries.id)
        #expect(try await dependencies.transactionRepository.transaction(id: consciouslyCategorized.id)?.categoryID == Category.restaurants.id)
        #expect(model.items.allSatisfy {
            $0.reason != .uncategorized
                || ($0.transaction.id != selected.id && $0.transaction.id != matchingUncategorized.id)
        })
        let initialRule = try #require(await dependencies.ruleRepository.rules().first)
        #expect(initialRule.condition == .merchantIDEquals(merchantID))
        #expect(dependencies.changeTracker.revision == revisionBefore + 1)

        let corrected = transaction()
        try await dependencies.transactionRepository.upsert([corrected])
        await model.assignCategory(
            ReviewItem(transaction: corrected, reason: .uncategorized),
            categoryID: Category.restaurants.id,
            scope: .merchant
        )

        let rules = try await dependencies.ruleRepository.rules()
        #expect(rules.count == 1)
        #expect(rules.first?.id == initialRule.id)
        #expect(rules.first?.categoryID == Category.restaurants.id)
        #expect(try await dependencies.transactionRepository.transaction(id: matchingUncategorized.id)?.categoryID == Category.groceries.id)
    }

    @Test("Review lehnt Aggregationskategorien als direktes Ziel ab")
    func reviewRejectsParentCategory() async throws {
        let dependencies = try makeDependencies(failUpsert: false)
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        let transaction = uncategorizedItem()
        try await dependencies.transactionRepository.upsert([transaction])
        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()
        let item = try #require(model.items.first { $0.transaction.id == transaction.id })

        await model.assignCategory(item, categoryID: Category.food.id)

        #expect(model.errorMessage != nil)
        #expect(try await dependencies.transactionRepository.transaction(id: transaction.id)?.categoryID == nil)
        #expect(model.items.contains { $0.id == item.id })
    }

    @Test("Transfer-Markierung behält beide Buchungen und schließt deren Review ab")
    func transferActionIsNonDestructive() async throws {
        let dependencies = try makeDependencies(failUpsert: false)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let debit = Transaction(
            accountID: account.id,
            source: .manual,
            amount: Money(amount: -50, currency: .eur),
            bookedAt: Date(),
            rawMerchantName: "Eigenübertrag"
        )
        let credit = Transaction(
            accountID: account.id,
            source: .manual,
            amount: Money(amount: 50, currency: .eur),
            bookedAt: Date(),
            rawMerchantName: "Eigenübertrag"
        )
        try await dependencies.transactionRepository.upsert([debit, credit])
        let item = ReviewItem(
            transaction: debit,
            reason: .possibleTransfer,
            linkedTransactionID: credit.id
        )
        let model = ReviewQueueModel(dependencies: dependencies)

        await model.markAsTransfer(item, linkedTransactionID: credit.id)

        #expect(try await dependencies.transactionRepository.count() == 2)
        let annotations = try await dependencies.transactionAnnotationRepository.annotations(
            transactionIDs: [debit.id, credit.id]
        )
        #expect(annotations.count == 2)
        #expect(annotations.allSatisfy { $0.manualKindOverride == .transfer && $0.reviewed })
        #expect(model.errorMessage == nil)
    }

    @Test("Workspace bündelt mehrere Hinweise pro Transaktion")
    func workspaceBundlesReasonsByTransaction() async throws {
        let dependencies = try makeDependencies(failUpsert: false)
        let account = Account(name: "USD-Karte", type: .creditCard, currency: .usd, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        var transaction = uncategorizedItem()
        transaction.accountID = account.id
        transaction.amount = Money(amount: -12, currency: .usd)
        try await dependencies.transactionRepository.upsert([transaction])

        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()

        let entry = try #require(model.entries.first { $0.id == transaction.id })
        #expect(model.items.filter { $0.transaction.id == transaction.id }.count == 2)
        #expect(model.entries.filter { $0.id == transaction.id }.count == 1)
        #expect(entry.reasons == [.uncategorized, .foreignCurrency])
        #expect(entry.primaryAction == .categorize)
    }

    @Test("Ähnliche Händler entsprechen exakt der später gespeicherten Regel")
    func similarMerchantCountUsesLearnedRuleSemantics() async throws {
        let dependencies = try makeDependencies(failUpsert: false)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        func transaction(merchant: String) -> Transaction {
            Transaction(
                accountID: account.id,
                source: .openBanking,
                amount: Money(amount: -8, currency: .eur),
                bookedAt: Date(),
                rawMerchantName: merchant
            )
        }

        let first = transaction(merchant: "SPAR 1234")
        let second = transaction(merchant: "SPAR 9876")
        let unrelated = transaction(merchant: "SPARROW STORE")
        try await dependencies.transactionRepository.upsert([first, second, unrelated])

        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()
        let entry = try #require(model.entries.first { $0.id == first.id })

        #expect(model.similarUncategorizedCount(for: entry) == 2)
    }

    @Test("Kategorie-Menü gruppiert Leaves, ohne Parent-Kategorien anzubieten")
    func categoryMenuKeepsLeafOnlySemantics() async throws {
        let dependencies = try makeDependencies(failUpsert: false)
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        let transaction = uncategorizedItem()
        try await dependencies.transactionRepository.upsert([transaction])

        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()

        let offeredIDs = Set(
            model.categoryGroups.flatMap { $0.categories.map(\.id) }
                + model.standaloneCategories.map(\.id)
        )
        let expectedIDs = Set(model.assignableCategories.map(\.id))
        let parentIDs = Set(model.categoryGroups.map(\.parent.id))

        #expect(offeredIDs == expectedIDs)
        #expect(offeredIDs.isDisjoint(with: parentIDs))
    }
}

struct BrokenReadRepository: TransactionRepository {
    struct ReadFailed: Error {}

    func transactions(matching query: TransactionQuery) async throws -> [Transaction] {
        throw ReadFailed()
    }

    func transactions(accountID: UUID, source: TransactionSource) async throws -> [Transaction] { [] }
    func recentTransactions(limit: Int) async throws -> [Transaction] { [] }
    func transactionPage(matching q: TransactionQuery, sort: TransactionSortOrder, offset: Int, limit: Int) async throws -> TransactionPage {
        .init(transactions: [], hasMore: false)
    }
    func transaction(id: UUID) async throws -> Transaction? { nil }
    func upsert(_ t: [Transaction]) async throws {}
    func deleteTransactions(importBatchID: UUID) async throws {}
    func deleteTransactions(ids: Set<UUID>) async throws {}
    func count() async throws -> Int { 0 }
    func deleteAllDemoTransactions() async throws {}

    func deleteAll() async throws {}
}
