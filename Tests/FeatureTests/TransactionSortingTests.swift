import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("TransactionSorting")
struct TransactionSortingTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func makeModel(_ dependencies: AppDependencies) -> TransactionsModel {
        TransactionsModel(dependencies: dependencies)
    }

    @Test("Betragssortierung ist currency-first, deterministisch, ohne FX")
    func amountSortCrossCurrency() async throws {
        let dependencies = try makeDependencies()
        let model = makeModel(dependencies)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let calendar = Calendar(identifier: .gregorian)
        func txn(_ id: String, _ amount: Decimal, _ currency: CurrencyCode, dayOffset: Int) -> Transaction {
            Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: id,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: amount, currency: currency),
                bookedAt: calendar.date(byAdding: .day, value: -dayOffset, to: Date()),
                rawDescription: id,
                rawMerchantName: id,
                merchantDisplayName: id
            )
        }

        // Bewusst unsortiert und cross-currency:
        let rows = [
            txn("USD100", Decimal(string: "100.00")!, .usd, dayOffset: 1),
            txn("EUR10", Decimal(string: "10.00")!, .eur, dayOffset: 2),
            txn("EUR90", Decimal(string: "90.00")!, .eur, dayOffset: 3),
            txn("USD5", Decimal(string: "5.00")!, .usd, dayOffset: 4)
        ]
        try await dependencies.transactionRepository.upsert(rows)

        await model.refresh()

        // WP21: Spaltenkopf-Sortierung = globale Store-Sortierung (Refresh).
        // Ascending: Währung alphabetisch zuerst, Beträge innerlich aufsteigend
        model.tableSortOrder = [KeyPathComparator(\.amountSortValue, order: .forward)]
        await model.applyTableSort()

        let ascending = model.transactions.map { "\($0.rawMerchantName!)" }
        #expect(ascending == ["EUR10", "EUR90", "USD5", "USD100"])

        // Descending: Richtung invertiert in beiden Ebenen
        model.tableSortOrder = [KeyPathComparator(\.amountSortValue, order: .reverse)]
        await model.applyTableSort()

        let descending = model.transactions.map { "\($0.rawMerchantName!)" }
        #expect(descending == ["USD100", "USD5", "EUR90", "EUR10"])
    }

    @Test("Datumssortierung nutzt native Comparators")
    func dateSort() async throws {
        let dependencies = try makeDependencies()
        let model = makeModel(dependencies)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let calendar = Calendar(identifier: .gregorian)
        let rows = [
            Transaction(
                id: UUID(), accountID: account.id, source: .demo, externalID: "old",
                status: .booked, kind: .purchase,
                amount: Money(amount: -Decimal(5), currency: .eur),
                bookedAt: calendar.date(byAdding: .day, value: -10, to: Date()),
                rawDescription: "old", rawMerchantName: "old", merchantDisplayName: "old"
            ),
            Transaction(
                id: UUID(), accountID: account.id, source: .demo, externalID: "new",
                status: .booked, kind: .purchase,
                amount: Money(amount: -Decimal(6), currency: .eur),
                bookedAt: calendar.date(byAdding: .day, value: -1, to: Date()),
                rawDescription: "new", rawMerchantName: "new", merchantDisplayName: "new"
            )
        ]
        try await dependencies.transactionRepository.upsert(rows)
        await model.refresh()

        // WP21: Sortierwechsel = Store-Query (global über alle Seiten).
        model.tableSortOrder = [KeyPathComparator(\.displayDate, order: .forward)]
        await model.applyTableSort()
        #expect(model.transactions.first?.externalID == "old")

        model.tableSortOrder = [KeyPathComparator(\.displayDate, order: .reverse)]
        await model.applyTableSort()
        #expect(model.transactions.first?.externalID == "new")
    }
}
