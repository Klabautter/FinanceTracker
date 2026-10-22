import Foundation
import Testing

@testable import FinanceTracker

@Suite("Cashback-Summe in der Auswertung")
struct CashbackTotalsTests {
    private func purchase(_ amount: Decimal, currency: CurrencyCode = .eur, cashback: Decimal?, status: TransactionStatus = .booked) -> Transaction {
        Transaction(
            accountID: UUID(),
            source: .etherFiCashCSV,
            status: status,
            kind: .purchase,
            amount: Money(amount: -amount, currency: currency),
            bookedAt: Date(timeIntervalSince1970: 1_790_000_000),
            rawDescription: "Laden",
            rawMerchantName: "Laden",
            merchantDisplayName: "Laden",
            cashbackAmount: cashback,
            cashbackCurrency: cashback == nil ? nil : currency
        )
    }

    @Test("Cashback wird je Währung summiert und nicht mit Ausgaben verrechnet")
    func cashbackIsSeparate() {
        let usd = CurrencyCode("USD")
        let transactions = [
            purchase(100, cashback: 3),
            purchase(8, cashback: Decimal(string: "0.24")),
            purchase(20, cashback: nil),
            purchase(10, currency: usd, cashback: Decimal(string: "0.30")),
            purchase(50, cashback: Decimal(string: "1.50"), status: .cancelled)
        ]
        let snapshot = AnalyticsCalculator(baseCurrency: .eur).snapshot(transactions: transactions, categories: [])

        #expect(snapshot.cashbackTotals == [
            CashbackTotal(currency: .eur, amount: Decimal(string: "3.24")!),
            CashbackTotal(currency: usd, amount: Decimal(string: "0.30")!)
        ])
        // Stornierte Buchung zählt weder bei Ausgaben noch beim Cashback.
        // Die EUR-Ausgaben bleiben brutto: 100 + 8 + 20, ohne Cashback-Abzug.
        let eurOnly = AnalyticsCalculator(baseCurrency: .eur).snapshot(
            transactions: transactions.filter { $0.amount.currency == .eur },
            categories: []
        )
        #expect(eurOnly.totalSpending == 128)
    }

    @Test("Ohne Cashback bleibt die Liste leer")
    func noCashback() {
        let snapshot = AnalyticsCalculator(baseCurrency: .eur).snapshot(
            transactions: [purchase(20, cashback: nil), purchase(5, cashback: 0)],
            categories: []
        )
        #expect(snapshot.cashbackTotals.isEmpty)
    }
}
