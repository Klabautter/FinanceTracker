import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

/// Kontrollierbares Gate: hält Query-Ergebnisse an, bis der Test öffnet.
final class GatedTransactionRepository: TransactionRepository, @unchecked Sendable {
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            let shouldWait: Bool = lock.withLock { !isOpen }
            guard shouldWait else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if isOpen {
                        return true
                    }
                    continuations.append(continuation)
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        }

        func open() {
            let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
                isOpen = true
                let all = continuations
                continuations = []
                return all
            }
            toResume.forEach { $0.resume() }
        }
    }

    let base: any TransactionRepository
    /// Query-Kategorie-Set → Gate. Enthält eine Query dieses Set, wartet sie.
    private let gates: [Set<UUID>: Gate]
    private let lock = NSLock()
    private var categorySetsStorage: [Set<UUID>] = []

    init(base: any TransactionRepository, gates: [Set<UUID>: Gate]) {
        self.base = base
        self.gates = gates
    }

    func transactions(matching query: TransactionQuery) async throws -> [Transaction] {
        lock.withLock { categorySetsStorage.append(query.categoryIDs) }
        if let gate = gates[query.categoryIDs] {
            await gate.wait()
        }
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
@Suite("AnalyticsLoadRace")
struct AnalyticsLoadRaceTests {

    @Test("Kategorienfilter verwendet Split-Anteile und erhält Originalbuchungen im Drill-down")
    func splitCategoryScope() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        let selected = Category(name: "Essen", systemIconName: "cart")
        let other = Category(name: "Wohnen", systemIconName: "house")
        let obsoleteParent = Category(name: "Alte Zuordnung", systemIconName: "folder")
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.categoryRepository.upsert([selected, other, obsoleteParent])
        let transaction = Transaction(
            accountID: account.id, source: .demo, status: .booked, kind: .purchase,
            amount: Money(amount: -100, currency: .eur), bookedAt: Date(),
            categoryID: obsoleteParent.id
        )
        try await dependencies.transactionRepository.upsert([transaction])
        try await dependencies.transactionSplitRepository.upsert([
                TransactionSplitLine(parentTransactionID: transaction.id, amount: 30, categoryID: selected.id),
                TransactionSplitLine(parentTransactionID: transaction.id, amount: 70, categoryID: other.id)
            ])
        let model = AnalyticsModel(dependencies: dependencies)
        model.filterCategoryIDs = [selected.id]
        await model.load()
        #expect(model.errorMessage == nil)
        #expect(model.snapshot?.totalSpending == 30)
        #expect(model.snapshot?.transactionCount == 1)
        #expect(model.snapshot?.spendingByCategory.map(\.amount) == [30])
        #expect(model.monthlyPoints.last?.spending == 30)
        var query = TransactionQuery()
        query.categoryIDs = [selected.id]
        let page = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .dateDescending, offset: 0, limit: 1
        )
        #expect(page.transactions.map(\.id) == [transaction.id])
        #expect(page.transactions.first?.amount.amount == -100)
        let tag = Tag(name: "Prüfung")
        try await dependencies.tagRepository.upsert([tag])
        var taggedTransaction = transaction
        taggedTransaction.tagIDs = [tag.id]
        try await dependencies.transactionRepository.upsert([taggedTransaction])
        query.tagIDs = [tag.id]
        let taggedPage = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .dateDescending, offset: 0, limit: 1
        )
        #expect(taggedPage.transactions.map(\.id) == [transaction.id])
        let sortedPage = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .amountAscending, offset: 0, limit: 1
        )
        #expect(sortedPage.transactions.map(\.id) == [transaction.id])
        query.categoryIDs = [obsoleteParent.id]
        let replacedParent = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .dateDescending, offset: 0, limit: 1
        )
        #expect(replacedParent.transactions.isEmpty)
    }

    @Test("Rapid-Filterwechsel: letzter Filter gewinnt, stale Load committet nicht")
    func rapidFilterChanges() async throws {
        let store = try SwiftDataStore(inMemory: true)
        var dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        // Zwei Filter-Sets mit unterscheidbaren Beträgen.
        let slowCategory = UUID()
        let fastCategory = UUID()

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        func expense(_ amount: Decimal, categoryID: UUID) -> Transaction {
            Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: UUID().uuidString,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -amount, currency: .eur),
                bookedAt: Date(),
                rawDescription: "Händler",
                rawMerchantName: "Händler",
                merchantDisplayName: "Händler",
                categoryID: categoryID
            )
        }

        try await dependencies.transactionRepository.upsert([
            expense(111, categoryID: slowCategory),
            expense(222, categoryID: fastCategory)
        ])

        // Gate: Die SLOW-Query wartet, bis der Test öffnet.
        let gate = GatedTransactionRepository.Gate()
        let gated = GatedTransactionRepository(
            base: dependencies.transactionRepository,
            gates: [[slowCategory]: gate]
        )
        dependencies = AppDependencies(
            transactionRepository: gated,
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

        let model = AnalyticsModel(dependencies: dependencies)

        // 1) Filter A (langsam) starten: Load hängt im Gate.
        model.filterCategoryIDs = [slowCategory]
        let staleLoad = Task { await model.load() }
        // Dem MainActor-Zyklus Zeit geben, bis der Load im Gate wartet.
        try await Task.sleep(for: .milliseconds(200))

        // 2) Filter B (schnell) laden, committet sofort.
        model.filterCategoryIDs = [fastCategory]
        await model.load()
        #expect(model.snapshot?.totalSpending == 222)
        #expect(model.isLoading == false)

        // 3) Gate öffnen: der STALE A-Load läuft weiter und will committen.
        gate.open()
        await staleLoad.value

        // 4) Final UI muss B zeigen: A darf nicht überschrieben haben.
        #expect(model.snapshot?.totalSpending == 222)
        #expect(model.errorMessage == nil)
        #expect(model.isLoading == false)

        // Ein anschließender Filterwechsel entfernt das alte Ergebnis schon
        // synchron, bevor der neue unstrukturierte Load-Task anlaufen kann.
        model.filterCategoryIDs = [slowCategory]
        model.filtersChanged()
        #expect(model.isLoading)
        #expect(model.snapshot == nil)
        #expect(model.previousSnapshot == nil)

        gate.open()
        while model.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Error eines stale Loads überschreibt den aktuellen Zustand nicht")
    func staleErrorDoesNotOverwrite() async throws {
        let store = try SwiftDataStore(inMemory: true)
        var dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        let slowCategory = UUID()
        let fastCategory = UUID()

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        func expense(_ amount: Decimal, categoryID: UUID) -> Transaction {
            Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: UUID().uuidString,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -amount, currency: .eur),
                bookedAt: Date(),
                rawDescription: "Händler",
                rawMerchantName: "Händler",
                merchantDisplayName: "Händler",
                categoryID: categoryID
            )
        }
        try await dependencies.transactionRepository.upsert([
            expense(111, categoryID: slowCategory),
            expense(222, categoryID: fastCategory)
        ])

        let gate = GatedTransactionRepository.Gate()
        let gated = GatedTransactionRepository(
            base: dependencies.transactionRepository,
            gates: [[slowCategory]: gate]
        )
        dependencies = AppDependencies(
            transactionRepository: gated,
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

        let model = AnalyticsModel(dependencies: dependencies)

        model.filterCategoryIDs = [slowCategory]
        let staleLoad = Task { await model.load() }
        try await Task.sleep(for: .milliseconds(200))

        model.filterCategoryIDs = [fastCategory]
        await model.load()
        #expect(model.snapshot?.totalSpending == 222)
        #expect(model.errorMessage == nil)

        gate.open()
        await staleLoad.value

        // Kein Stale-Error, gültiges B-Ergebnis bleibt stehen.
        #expect(model.errorMessage == nil)
        #expect(model.snapshot?.totalSpending == 222)
    }
}
