import Foundation
import Testing

@testable import FinanceTracker

/// Tanken alle neun Tage mit schwankendem Betrag ist keine Fixkost, auch
/// wenn zufällig vier ähnliche Beträge im Monatsabstand liegen.
@Suite("RecurringFluctuatingMerchant")
struct RecurringFluctuatingMerchantTests {
    private func txn(_ merchant: String, _ amount: Decimal, _ date: Date, account: UUID) -> Transaction {
        Transaction(
            accountID: account, source: .demo, externalID: UUID().uuidString, status: .booked, kind: .purchase,
            amount: Money(amount: -amount, currency: .eur), bookedAt: date,
            rawDescription: merchant, rawMerchantName: merchant, merchantDisplayName: merchant
        )
    }

    @Test("Schwankender Händler mit zufälligen Betragsstufen ergibt keinen Vorschlag")
    func fuelIsNotRecurring() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 5, day: 3))!
        let account = UUID()
        // Alle 9 Tage tanken; jede dritte Füllung zufällig um 54 €.
        let amounts: [Decimal] = [43.10, 66.40, 54.20, 71.85, 48.30, 54.75, 77.10, 45.60, 54.40,
                                  62.15, 49.90, 54.95, 68.30, 42.75, 54.60, 73.20, 51.10, 55.05, 60.40, 47.20]
        let transactions = amounts.enumerated().map { index, amount in
            txn("SHELL", amount, calendar.date(byAdding: .day, value: index * 9, to: start)!, account: account)
        }
        let now = calendar.date(byAdding: .day, value: 185, to: start)!
        let series = RecurringPaymentsDetector().detect(transactions: transactions, calendar: calendar, now: now)
        #expect(series.isEmpty)
    }
}
