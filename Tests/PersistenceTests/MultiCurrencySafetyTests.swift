import Foundation
import Testing

@testable import FinanceTracker

@Suite("MultiCurrencySafety")
struct MultiCurrencySafetyTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func txn(amount: Decimal, currency: CurrencyCode, accountID: UUID) -> Transaction {
        Transaction(
            accountID: accountID,
            source: .legacyCardExportCSV,
            amount: Money(amount: amount, currency: currency),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: 5))
        )
    }

    @Test("AccountsModel summiert niemals Fremdwährungen in Kontowährung")
    func accountSummaryExcludesForeignCurrencies() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        let eurAccount = Account(name: "EUR Card", type: .cryptoCard, currency: .eur, source: .csvImport)
        try await dependencies.accountRepository.upsert([eurAccount])

        try await dependencies.transactionRepository.upsert([
            txn(amount: -100, currency: .eur, accountID: eurAccount.id),
            txn(amount: -20, currency: .usd, accountID: eurAccount.id),
            txn(amount: 50, currency: .gbp, accountID: eurAccount.id)
        ])

        let model = await MainActor.run { AccountsModel(dependencies: dependencies) }
        await model.load()

        let summaries = await MainActor.run { model.accounts }
        #expect(summaries.count == 1)

        let summary = summaries[0]
        #expect(summary.netMovement.amount == -100)
        #expect(summary.netMovement.currency == .eur)
        #expect(summary.foreignCurrencies == [.usd, .gbp])
    }

    @Test("AnalyticsSnapshot rechnet Fremdwährungen transparent zum Referenzkurs um")
    func analyticsConvertsForeignCurrencies() {
        let calculator = AnalyticsCalculator(baseCurrency: .eur)
        let accountID = UUID()
        let transactions = [
            txn(amount: -100, currency: .eur, accountID: accountID),
            txn(amount: -20, currency: .usd, accountID: accountID),
            txn(amount: 30, currency: .usd, accountID: accountID),
            txn(amount: -5, currency: .eur, accountID: accountID)
        ]

        let snapshot = calculator.snapshot(transactions: transactions, categories: [], calendar: calendar)

        // 100 + 5 EUR + 20 USD × 0.92 = 123.4; Einnahmen: 30 USD × 0.92 = 27.6
        // (Referenzkurse sind exakte Dezimalwerte, direkte Decimal-Vergleiche)
        #expect(snapshot.totalSpending == Decimal(string: "123.4"))
        #expect(snapshot.totalIncome == Decimal(string: "27.6"))
        #expect(snapshot.convertedForeignTransactionCount == 2)
        #expect(snapshot.convertedCurrencies == [.usd])
        #expect(snapshot.excludedForeignTransactionCount == 0)
        #expect(snapshot.excludedCurrencies.isEmpty)
    }
}
