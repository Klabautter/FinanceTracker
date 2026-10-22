import Foundation
import Testing

@testable import FinanceTracker

/// MacUX-Perf: Eigene Edits des Transaktions-Screens dürfen keinen
/// Full-Refetch auslösen (Zeile ist bereits in-memory aktualisiert)
/// nur externe Änderungen (Import, andere Screens) triggern `.refresh()`.
/// Die View entscheidet über `dataRevision != lastLocalRevision`.
@MainActor
@Suite("TransactionsRefreshSkip")
struct TransactionsRefreshSkipTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    @Test("Monats-Drilldown bewahrt Konten-, Kategorien- und Quellenfilter und lässt sich entfernen")
    func inheritedAnalyticsScope() async throws {
        let dependencies = try makeDependencies()
        let account = Account(name: "Scope", type: .checking, currency: .eur, source: .demo)
        try await dependencies.accountRepository.upsert([account])
        let date = Date()
        let interval = DateInterval(start: date.addingTimeInterval(-60), end: date.addingTimeInterval(60))
        let matching = Transaction(accountID: account.id, source: .demo, status: .booked,
                                   amount: Money(amount: -10, currency: .eur), bookedAt: date,
                                   categoryID: Category.groceries.id)
        let otherAccount = Transaction(accountID: UUID(), source: .demo, status: .booked,
                                       amount: Money(amount: -20, currency: .eur), bookedAt: date,
                                       categoryID: Category.groceries.id)
        let otherSource = Transaction(accountID: account.id, source: .manual, status: .booked,
                                      amount: Money(amount: -30, currency: .eur), bookedAt: date,
                                      categoryID: Category.groceries.id)
        let otherCategory = Transaction(accountID: account.id, source: .demo, status: .booked,
                                        amount: Money(amount: -40, currency: .eur), bookedAt: date,
                                        categoryID: Category.restaurants.id)
        try await dependencies.transactionRepository.upsert([matching, otherAccount, otherSource, otherCategory])
        var query = TransactionQuery()
        query.accountIDs = [account.id]
        query.categoryIDs = [Category.groceries.id]
        query.sources = [.demo]
        let scope = AnalyticsScope(rangeTitle: "Test", query: query, accountNames: [account.name],
                                   categoryNames: ["Lebensmittel"], source: .demo).inMonth(interval)
        #expect(scope.query.accountIDs == query.accountIDs)
        let model = TransactionsModel(dependencies: dependencies)
        await model.setAnalyticsScope(scope).value
        #expect(model.visibleTransactions.map(\.id) == [matching.id])
        #expect(model.inheritedAnalyticsScope?.summary.contains(account.name) == true)
        await model.setMonthFilter(nil)?.value
        #expect(model.inheritedAnalyticsScope == nil)
        #expect(model.visibleTransactions.count == 4)
    }

    @Test("Nach Refresh und eigenem Edit sind Revisionen identisch (Skip), externer Bump weicht ab (Refresh)")
    func localEditsSkipExternalChangesRefresh() async throws {
        let dependencies = try makeDependencies()
        let model = TransactionsModel(dependencies: dependencies)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        try await dependencies.transactionRepository.upsert([
            Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: "skip-1",
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -Decimal(10), currency: .eur),
                bookedAt: Date(),
                rawDescription: "x",
                rawMerchantName: "X",
                merchantDisplayName: "X"
            )
        ])

        await model.refresh()
        #expect(model.hasLoadedData)

        // Frisch geladen: View darf nicht noch einmal refreshen.
        #expect(model.dataRevision == model.lastLocalRevision)

        // Eigener Edit: Revisionen bleiben identisch → Skip.
        let txn = try #require(model.visibleTransactions.first)
        await model.toggleReviewed(txn, reviewed: true)
        #expect(model.dataRevision > 0)
        #expect(model.dataRevision == model.lastLocalRevision, "Eigener Edit darf keinen External-Refresh triggern")

        // Externer Bump (z. B. Import in anderem Screen): abweichend → Refresh.
        dependencies.changeTracker.markChanged()
        #expect(model.dataRevision != model.lastLocalRevision)
    }

    @Test("createRule aktualisiert einen konfliktbehafteten Lernschlüssel statt ihn zu duplizieren")
    func createRuleUpdatesExistingLearningKey() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        let merchantID = UUID()
        let transaction = Transaction(
            accountID: UUID(),
            source: .openBanking,
            status: .booked,
            amount: Money(amount: -10, currency: .eur),
            bookedAt: Date(),
            rawMerchantName: "SPAR MARKT",
            merchantID: merchantID,
            merchantDisplayName: "SPAR",
            categoryID: Category.restaurants.id
        )
        try await dependencies.transactionRepository.upsert([transaction])
        let existing = CategoryRule(
            priority: 10,
            condition: .merchantIDEquals(merchantID),
            categoryID: Category.groceries.id,
            origin: .user
        )
        try await dependencies.ruleRepository.upsert([existing])
        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()
        let loaded = try #require(model.transaction(withID: transaction.id))

        #expect(await model.createRule(from: loaded))

        let rules = try await dependencies.ruleRepository.rules()
        #expect(rules.count == 1)
        #expect(rules.first?.id == existing.id)
        #expect(rules.first?.categoryID == Category.restaurants.id)
        #expect(model.dataRevision == model.lastLocalRevision)
    }

    @Test("Detail-Ladung holt die exakte Transaktion statt nur die erste Seite")
    func detailLoadTargetsExactTransaction() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        try await dependencies.accountRepository.upsert([account])
        let transaction = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .demo,
            externalID: "detail-target",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -12, currency: .eur),
            bookedAt: Date(),
            rawMerchantName: "BILLA",
            merchantDisplayName: "BILLA"
        )
        try await dependencies.transactionRepository.upsert([transaction])

        let model = TransactionsModel(dependencies: dependencies)
        await model.load(transactionID: transaction.id)

        #expect(model.errorMessage == nil)
        #expect(model.transactions.map(\.id) == [transaction.id])
        #expect(model.account(for: model.transactions[0])?.name == "Giro")
        #expect(!model.assignableCategories.isEmpty)
    }

    @Test("Kategorie merken erstellt eine Regel und kategorisiert gleiche Händler mit")
    func rememberedCategoryBackfillsMerchant() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        try await dependencies.accountRepository.upsert([account])
        let merchantID = UUID()
        let transactions = ["learn-1", "learn-2"].map { externalID in
            Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: externalID,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -12, currency: .eur),
                bookedAt: Date(),
                rawMerchantName: "BILLA FILIALE",
                merchantID: merchantID,
                merchantDisplayName: "BILLA"
            )
        }
        try await dependencies.transactionRepository.upsert(transactions)

        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()
        let selected = try #require(model.transactions.first)
        await model.assignCategory(selected, to: Category.groceries.id, rememberMerchant: true)

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.allSatisfy { $0.categoryID == Category.groceries.id })
        #expect(try await dependencies.ruleRepository.rules().contains {
            $0.condition == .merchantIDEquals(merchantID) && $0.categoryID == Category.groceries.id
        })
    }
}
