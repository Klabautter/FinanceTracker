import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

/// WP14: Das Dashboard darf keinen Full-History-Query mehr fahren
/// Recording-Repos beweisen den Scope.
/// WP37: ASan zeigte einen append-Race bei parallelen async-let-Loads
/// Zugriffe sind jetzt gelockt.
final class RecordingTransactionRepository: TransactionRepository, @unchecked Sendable {
    let base: any TransactionRepository
    private let lock = NSLock()
    private var queriesStorage: [TransactionQuery] = []

    var recordedQueries: [TransactionQuery] {
        lock.withLock { queriesStorage }
    }

    init(base: any TransactionRepository) {
        self.base = base
    }

    func transactions(matching query: TransactionQuery) async throws -> [Transaction] {
        lock.withLock { queriesStorage.append(query) }
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

    /// WP13: Die Review-Projection ist ein genehmigter globaler Light-Pfad
    /// (propertiesToFetch statt Full-Hydration), kein Scope-Verstoß und
    /// wird daher nicht als paged Query aufgezeichnet.
    func reviewCandidateTransactions() async throws -> [Transaction] {
        try await base.reviewCandidateTransactions()
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

final class RecordingImportBatchRepository: ImportBatchRepository, @unchecked Sendable {
    let base: any ImportBatchRepository
    private(set) var batchesCallCount = 0
    private(set) var latestBatchCallCount = 0

    init(base: any ImportBatchRepository) {
        self.base = base
    }

    func batches() async throws -> [ImportBatch] {
        batchesCallCount += 1
        return try await base.batches()
    }

    func latestBatch() async throws -> ImportBatch? {
        latestBatchCallCount += 1
        return try await base.latestBatch()
    }

    func batch(id: UUID) async throws -> ImportBatch? {
        try await base.batch(id: id)
    }

    func upsert(_ batches: [ImportBatch]) async throws {
        try await base.upsert(batches)
    }

    func delete(id: UUID) async throws {
        try await base.delete(id: id)
    }

    func deleteAll() async throws {
        try await base.deleteAll()
    }

    func commitImport(batch: ImportBatch, inserts: [Transaction], updates: [Transaction]) async throws {
        try await base.commitImport(batch: batch, inserts: inserts, updates: updates)
    }

    func rollbackImportBatch(id: UUID) async throws {
        try await base.rollbackImportBatch(id: id)
    }
}

final class RecordingSplitRepository: TransactionSplitRepository, @unchecked Sendable {
    let base: any TransactionSplitRepository
    private(set) var allSplitLinesCallCount = 0
    private(set) var scopedCallCount = 0

    init(base: any TransactionSplitRepository) {
        self.base = base
    }

    func allSplitLines() async throws -> [TransactionSplitLine] {
        allSplitLinesCallCount += 1
        return try await base.allSplitLines()
    }

    func deleteAll() async throws {
        try await base.deleteAll()
    }

    func splitLines(parentTransactionID: UUID) async throws -> [TransactionSplitLine] {
        try await base.splitLines(parentTransactionID: parentTransactionID)
    }

    func splitLines(parentTransactionIDs: Set<UUID>) async throws -> [TransactionSplitLine] {
        scopedCallCount += 1
        return try await base.splitLines(parentTransactionIDs: parentTransactionIDs)
    }

    func upsert(_ lines: [TransactionSplitLine]) async throws {
        try await base.upsert(lines)
    }

    func deleteAll(parentTransactionID: UUID) async throws {
        try await base.deleteAll(parentTransactionID: parentTransactionID)
    }
}

@MainActor
@Suite("DashboardScope")
struct DashboardScopeTests {

    @Test("Dashboard-Trend wird genau einmal in Prozentpunkte umgerechnet")
    func spendingTrendUsesPercentagePointsOnce() {
        let increase = DashboardModel.spendingTrendPercentagePoints(current: 125, previous: 100)
        let decreaseToZero = DashboardModel.spendingTrendPercentagePoints(current: 0, previous: 80)

        #expect(increase == 25)
        #expect(increase.map(DashboardModel.roundedTrendPercentage) == 25)
        #expect(decreaseToZero == -100)
        #expect(DashboardModel.spendingTrendPercentagePoints(current: 100, previous: 0) == nil)
    }

    @Test("First Run basiert auf globalem Transaktionsbestand, nicht auf aktuellem Monat")
    func firstRunUsesGlobalTransactionCount() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15)))

        let emptyModel = DashboardModel(dependencies: dependencies, calendar: calendar, now: { now })
        await emptyModel.load()
        #expect(emptyModel.hasAnyTransactions == false)

        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let oldDate = try #require(calendar.date(byAdding: .year, value: -1, to: now))
        let oldTransaction = Transaction(
            accountID: account.id,
            source: .manual,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -25, currency: .eur),
            bookedAt: oldDate,
            rawDescription: "Alt"
        )
        try await dependencies.transactionRepository.upsert([oldTransaction])

        let populatedModel = DashboardModel(dependencies: dependencies, calendar: calendar, now: { now })
        await populatedModel.load()
        #expect(populatedModel.hasAnyTransactions)
        #expect(populatedModel.snapshot?.transactionCount == 0)
    }

    @Test("Cashflow-Monatsintervall umfasst exakt den aktivierten Monat")
    func cashflowMonthInterval() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let tapped = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 12)))
        let interval = try #require(MonthlyCashflowChart.monthInterval(containing: tapped, calendar: calendar))

        #expect(calendar.component(.day, from: interval.start) == 1)
        #expect(calendar.component(.month, from: interval.start) == 8)
        #expect(calendar.component(.month, from: interval.end) == 9)
        #expect(interval.contains(tapped))
    }

    @Test("Kategorie-Drilldown übernimmt Zeitraum, effektive Semantik und Basisswährung")
    func categoryDrilldownMatchesDashboardSemantics() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let interval = DateInterval(
            start: try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))),
            end: try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        )
        let inside = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15)))
        let outside = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 31)))
        let parent = Category(name: "Essen", systemIconName: "fork.knife")
        let child = Category(name: "Restaurant", systemIconName: "cup.and.saucer", parentID: parent.id)
        let other = Category(name: "Reisen", systemIconName: "airplane")
        try await dependencies.categoryRepository.upsert([parent, child, other])
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        func transaction(
            id: UUID = UUID(),
            categoryID: UUID,
            date: Date = inside,
            currency: CurrencyCode = .eur,
            status: TransactionStatus = .booked,
            kind: TransactionKind = .purchase
        ) -> Transaction {
            Transaction(
                id: id,
                accountID: account.id,
                source: .manual,
                status: status,
                kind: kind,
                amount: Money(amount: -20, currency: currency),
                bookedAt: date,
                rawDescription: id.uuidString,
                categoryID: categoryID
            )
        }

        let directID = UUID()
        let descendantID = UUID()
        let excludedID = UUID()
        let overriddenID = UUID()
        let foreignID = UUID()
        let splitID = UUID()
        let uncategorizedID = UUID()
        var uncategorized = transaction(id: uncategorizedID, categoryID: other.id)
        uncategorized.categoryID = nil
        let rows = [
            transaction(id: directID, categoryID: parent.id),
            transaction(id: descendantID, categoryID: child.id),
            transaction(id: splitID, categoryID: other.id),
            uncategorized,
            transaction(categoryID: child.id, date: outside),
            transaction(id: foreignID, categoryID: child.id, currency: .usd),
            transaction(id: excludedID, categoryID: child.id),
            transaction(id: overriddenID, categoryID: child.id),
            transaction(categoryID: child.id, status: .cancelled),
            transaction(categoryID: child.id, kind: .refund),
            transaction(categoryID: other.id)
        ]
        try await dependencies.transactionRepository.upsert(rows)
        try await dependencies.transactionSplitRepository.upsert([
            TransactionSplitLine(parentTransactionID: splitID, amount: 12, categoryID: child.id),
            TransactionSplitLine(parentTransactionID: splitID, amount: 8)
        ])
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(transactionID: excludedID, excludedFromAnalytics: true),
            TransactionAnnotation(transactionID: overriddenID, manualKindOverride: .transfer)
        ])

        let model = CategoryDrilldownModel(
            categoryID: parent.id,
            dateInterval: interval,
            currency: .eur,
            dependencies: dependencies,
            pageSize: 2
        )
        await model.load()
        while model.canLoadMore {
            await model.loadNextPage()
        }

        #expect(Set(model.transactions.map(\.id)) == Set([directID, descendantID, foreignID, splitID]))
        #expect(model.transactions.allSatisfy { interval.contains($0.displayDate) })
        #expect(model.transactions.contains { $0.amount.currency == .usd })
        #expect(model.canLoadMore == false)
        #expect(model.errorMessage == nil)
        let uncategorizedModel = CategoryDrilldownModel(
            categoryID: nil, dateInterval: interval, currency: .eur,
            dependencies: dependencies, pageSize: 2
        )
        await uncategorizedModel.load()
        while uncategorizedModel.canLoadMore { await uncategorizedModel.loadNextPage() }
        #expect(uncategorizedModel.errorMessage == nil)
        #expect(Set(uncategorizedModel.transactions.map(\.id)) == [splitID, uncategorizedID])
    }

    @Test("Dashboard lädt nur interval-scoped Queries, kein Full-History-Load")
    func dashboardLoadsScopedOnly() async throws {
        let store = try SwiftDataStore(inMemory: true)
        var dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        // Ein Budget, damit der Budget-/Split-Pfad des Dashboards läuft.
        let categoryID = Category.groceries.id
        try await dependencies.categoryRepository.upsert([.groceries, .restaurants])
        try await dependencies.budgetRepository.upsert([
            Budget(name: "Test-Budget", amount: 200, categoryIDs: [categoryID])
        ])
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        let splitParent = Transaction(
            accountID: account.id,
            source: .demo,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -25, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Scoped-Ausgabe",
            categoryID: categoryID
        )
        let excludedTransaction = Transaction(
            accountID: account.id,
            source: .demo,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -50, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Ausgeschlossene Ausgabe",
            categoryID: categoryID
        )
        try await dependencies.transactionRepository.upsert([splitParent, excludedTransaction])
        try await dependencies.transactionSplitRepository.upsert([
            TransactionSplitLine(parentTransactionID: splitParent.id, amount: 10, categoryID: Category.groceries.id),
            TransactionSplitLine(parentTransactionID: splitParent.id, amount: 15, categoryID: Category.restaurants.id)
        ])
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(transactionID: excludedTransaction.id, excludedFromAnalytics: true)
        ])

        let recordingTxn = RecordingTransactionRepository(base: dependencies.transactionRepository)
        let recordingBatches = RecordingImportBatchRepository(base: dependencies.importBatchRepository)
        let recordingSplits = RecordingSplitRepository(base: dependencies.transactionSplitRepository)

        dependencies = AppDependencies(
            transactionRepository: recordingTxn,
            transactionAnnotationRepository: dependencies.transactionAnnotationRepository,
            transactionCollectionRepository: dependencies.transactionCollectionRepository,
            transactionCollectionOverrideRepository: dependencies.transactionCollectionOverrideRepository,
            accountRepository: dependencies.accountRepository,
            categoryRepository: dependencies.categoryRepository,
            merchantRepository: dependencies.merchantRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: recordingBatches,
            connectionRepository: dependencies.connectionRepository,
            budgetRepository: dependencies.budgetRepository,
            tagRepository: dependencies.tagRepository,
            transactionSplitRepository: recordingSplits,
            sharedExpenseShareRepository: dependencies.sharedExpenseShareRepository,
            recurringCommitmentRepository: dependencies.recurringCommitmentRepository,
            transactionAttachmentRepository: dependencies.transactionAttachmentRepository,
            bankProviderFactory: dependencies.bankProviderFactory,
            importProviders: dependencies.importProviders,
            changeTracker: dependencies.changeTracker,
            baseCurrency: dependencies.baseCurrency,
            notificationScheduler: dependencies.notificationScheduler
        )

        let model = DashboardModel(dependencies: dependencies)
        await model.load()

        #expect(model.errorMessage == nil)
        #expect(model.snapshot?.totalSpending == 25)
        #expect(model.snapshot?.spendingByCategory.first(where: { $0.categoryID == Category.groceries.id })?.amount == 10)
        #expect(model.snapshot?.spendingByCategory.first(where: { $0.categoryID == Category.restaurants.id })?.amount == 15)

        // Alle Transaction-Queries müssen interval-scoped sein.
        #expect(!recordingTxn.recordedQueries.isEmpty)
        for query in recordingTxn.recordedQueries {
            #expect(query.dateInterval != nil, "Unscoped Query gefunden: \(query)")
        }

        // Latest-Import läuft über latestBatch(), nie über batches().
        #expect(recordingBatches.latestBatchCallCount >= 1)
        #expect(recordingBatches.batchesCallCount == 0)

        // Split-Lines laufen scoped, nie über allSplitLines().
        #expect(recordingSplits.allSplitLinesCallCount == 0)
        #expect(recordingSplits.scopedCallCount >= 1)
    }

    @Test("Scoped Split-Query: nur Lines der angefragten Parents")
    func scopedSplitLines() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        func purchase(id: UUID, amount: Decimal) -> Transaction {
            Transaction(
                id: id,
                accountID: account.id,
                source: .demo,
                externalID: id.uuidString,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -amount, currency: .eur),
                bookedAt: Date(),
                rawDescription: "Händler",
                rawMerchantName: "Händler",
                merchantDisplayName: "Händler"
            )
        }

        let parentA = UUID()
        let parentB = UUID()
        let outside = UUID()
        try await dependencies.transactionRepository.upsert([
            purchase(id: parentA, amount: 90),
            purchase(id: parentB, amount: 50),
            purchase(id: outside, amount: 10)
        ])

        try await dependencies.transactionSplitRepository.upsert([
            TransactionSplitLine(parentTransactionID: parentA, amount: 60),
            TransactionSplitLine(parentTransactionID: parentA, amount: 30),
            TransactionSplitLine(parentTransactionID: parentB, amount: 50),
            TransactionSplitLine(parentTransactionID: outside, amount: 10)
        ])

        // Query nur für Parent A.
        let linesA = try await dependencies.transactionSplitRepository.splitLines(
            parentTransactionIDs: Set([parentA])
        )
        #expect(linesA.count == 2)
        #expect(linesA.allSatisfy { $0.parentTransactionID == parentA })

        // Query für A + B.
        let linesAB = try await dependencies.transactionSplitRepository.splitLines(
            parentTransactionIDs: Set([parentA, parentB])
        )
        #expect(linesAB.count == 3)

        // Leere Menge → leer.
        let empty = try await dependencies.transactionSplitRepository.splitLines(parentTransactionIDs: [])
        #expect(empty.isEmpty)

        // Latest batch: nil ohne Batches, kein Crash.
        #expect(try await dependencies.importBatchRepository.latestBatch() == nil)
    }
}
