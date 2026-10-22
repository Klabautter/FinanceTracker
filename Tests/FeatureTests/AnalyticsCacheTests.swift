import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

/// WP16: Analytics-Cache, bounded LRU, Revision-Invalidierung, Cache-Hits.
final class CountingTransactionRepository: TransactionRepository, @unchecked Sendable {
    let base: any TransactionRepository
    private let lock = NSLock()
    private var callCountStorage = 0

    var callCount: Int {
        lock.withLock { callCountStorage }
    }

    init(base: any TransactionRepository) {
        self.base = base
    }

    func transactions(matching query: TransactionQuery) async throws -> [Transaction] {
        lock.withLock { callCountStorage += 1 }
        return try await base.transactions(matching: query)
    }

    func transactionPage(
        matching query: TransactionQuery,
        sort: TransactionSortOrder,
        offset: Int,
        limit: Int
    ) async throws -> TransactionPage {
        try await base.transactionPage(matching: query, sort: sort, offset: offset, limit: limit)
    }

    func transactions(accountID: UUID, source: TransactionSource) async throws -> [Transaction] {
        try await base.transactions(accountID: accountID, source: source)
    }

    func recentTransactions(limit: Int) async throws -> [Transaction] {
        try await base.recentTransactions(limit: limit)
    }

    func transaction(id: UUID) async throws -> Transaction? {
        try await base.transaction(id: id)
    }

    func upsert(_ transactions: [Transaction]) async throws {
        try await base.upsert(transactions)
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

    func deleteAll() async throws {
        try await base.deleteAll()
    }

    func deleteAllDemoTransactions() async throws {
        try await base.deleteAllDemoTransactions()
    }
}

@MainActor
@Suite("AnalyticsCache")
struct AnalyticsCacheTests {

    private func makeDependencies(
        baseCurrency: CurrencyCode = .eur
    ) throws -> (AppDependencies, CountingTransactionRepository) {
        let store = try SwiftDataStore(inMemory: true)
        var dependencies = AppDependencies.make(container: store.container, baseCurrency: baseCurrency)
        let counting = CountingTransactionRepository(base: dependencies.transactionRepository)
        dependencies = AppDependencies(
            transactionRepository: counting,
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
            baseCurrency: baseCurrency,
            notificationScheduler: dependencies.notificationScheduler
        )
        return (dependencies, counting)
    }

    @Test("Same request nutzt den Cache, kein zweiter DB-Query")
    func cacheHitAvoidsSecondQuery() async throws {
        let (dependencies, counting) = try makeDependencies()
        let model = AnalyticsModel(dependencies: dependencies)

        await model.load()
        let afterFirst = counting.callCount
        #expect(afterFirst > 0)

        await model.load() // gleicher Key → Cache-Hit
        #expect(counting.callCount == afterFirst)
    }

    @Test("Unterschiedliche Filter → separate Cache-Einträge, Rückkehr = Hit")
    func differentFiltersSeparate() async throws {
        let (dependencies, counting) = try makeDependencies()
        let model = AnalyticsModel(dependencies: dependencies)

        let filterA = Set([UUID()])
        let filterB = Set([UUID()])

        model.filterCategoryIDs = filterA
        await model.load()
        let afterA = counting.callCount

        model.filterCategoryIDs = filterB
        await model.load()
        #expect(counting.callCount > afterA)

        // Zurück zu A → Cache-Hit (beide Einträge leben), kein neuer Query.
        let beforeReturn = counting.callCount
        model.filterCategoryIDs = filterA
        await model.load()
        #expect(counting.callCount == beforeReturn)
    }

    @Test("Filter hin und zurück stellt auch den Snapshot der Vorperiode wieder her")
    func returningToFilterRestoresPreviousSnapshot() async throws {
        let (dependencies, counting) = try makeDependencies()
        let accountA = Account(name: "A", type: .checking, currency: .eur, source: .demo)
        let accountB = Account(name: "B", type: .checking, currency: .eur, source: .demo)
        try await dependencies.accountRepository.upsert([accountA, accountB])

        let calendar = Calendar(identifier: .gregorian)
        // Anfang der Vorperiode: Der Trend vergleicht nur mit gedeckten Perioden.
        let monthStart = try #require(calendar.date(from: calendar.dateComponents([.year, .month], from: Date())))
        let previousStart = try #require(calendar.date(byAdding: .month, value: -5, to: monthStart))
        let previousDate = try #require(calendar.date(byAdding: .day, value: 3, to: previousStart))
        func expense(_ amount: Decimal, account: Account, date: Date) -> Transaction {
            Transaction(
                accountID: account.id,
                source: .demo,
                externalID: UUID().uuidString,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -amount, currency: .eur),
                bookedAt: date,
                rawMerchantName: "Test"
            )
        }
        try await dependencies.transactionRepository.upsert([
            expense(100, account: accountA, date: Date()),
            expense(25, account: accountA, date: previousDate),
            expense(200, account: accountB, date: Date()),
            expense(100, account: accountB, date: previousDate)
        ])

        let model = AnalyticsModel(dependencies: dependencies, calendar: calendar)
        model.range = .last3Months
        model.filterAccountIDs = [accountA.id]
        await model.load()
        #expect(model.snapshot?.totalSpending == 100)
        #expect(model.previousSnapshot?.totalSpending == 25)

        model.filterAccountIDs = [accountB.id]
        await model.load()
        #expect(model.snapshot?.totalSpending == 200)
        #expect(model.previousSnapshot?.totalSpending == 100)

        let callsBeforeReturn = counting.callCount
        model.filterAccountIDs = [accountA.id]
        await model.load()

        #expect(counting.callCount == callsBeforeReturn)
        #expect(model.snapshot?.totalSpending == 100)
        #expect(model.previousSnapshot?.totalSpending == 25)
        #expect(model.spendingTrendPercent == 3)
    }

    @Test("Data-Revision-Wechsel invalidiert den Cache")
    func revisionInvalidates() async throws {
        let (dependencies, counting) = try makeDependencies()
        let model = AnalyticsModel(dependencies: dependencies)

        await model.load()
        let afterFirst = counting.callCount

        await model.load()
        #expect(counting.callCount == afterFirst) // Cache-Hit

        dependencies.changeTracker.markChanged() // Revision ++
        await model.load()
        #expect(counting.callCount > afterFirst) // Cache invalidiert → neu geladen
    }

    @Test("LRU: über Kapazität hinaus wird der älteste Eintrag verdrängt")
    func lruEviction() async throws {
        let (dependencies, counting) = try makeDependencies()
        let model = AnalyticsModel(dependencies: dependencies)

        let filterSets: [Set<UUID>] = (0..<8).map { _ in [UUID()] }
        for set in filterSets {
            model.filterCategoryIDs = set
            await model.load()
        }
        let afterAll = counting.callCount

        // Erster Filter erneut → wurde verdrängt → neuer DB-Query.
        model.filterCategoryIDs = filterSets[0]
        await model.load()
        #expect(counting.callCount > afterAll)

        // Letzter Filter ist noch gecacht → Cache-Hit.
        let beforeLast = counting.callCount
        model.filterCategoryIDs = filterSets[7]
        await model.load()
        #expect(counting.callCount == beforeLast)
    }
}
