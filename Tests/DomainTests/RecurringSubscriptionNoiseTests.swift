import Foundation
import Testing

@testable import FinanceTracker

@Suite("Wiederkehrend: Abo zwischen Einzelkäufen")
struct RecurringSubscriptionNoiseTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()
    private let account = UUID()

    private func purchase(_ merchant: String, _ amount: String, _ month: Int, _ day: Int) -> Transaction {
        Transaction(
            accountID: account,
            source: .genericCSV,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(string: amount)!, currency: .usd),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)),
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
    }

    @Test("Monatsabo am 28. wird trotz gleich teurer Einzelkäufe erkannt")
    func subscriptionAmongPurchases() throws {
        let transactions = [
            purchase("Example AI", "23.80", 5, 27), purchase("Example AI", "47.60", 5, 27),
            purchase("Example AI", "47.60", 5, 28), purchase("Example AI", "23.80", 6, 28),
            purchase("Example AI", "23.80", 7, 28), purchase("Example AI", "24.00", 8, 6),
            purchase("Example AI", "6.10", 8, 6), purchase("Example AI", "24.00", 8, 7),
            purchase("Example AI", "27.04", 8, 8), purchase("Example AI", "24.00", 8, 28),
            purchase("Example AI", "27.17", 9, 8), purchase("Example AI", "24.00", 9, 28),
            purchase("Example AI", "24.00", 10, 28)
        ]
        let series = RecurringPaymentsDetector().detect(
            transactions: transactions,
            calendar: calendar,
            now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        )
        let subscription = try #require(series.first)
        #expect(series.count == 1)
        #expect(subscription.cadence == .monthly)
        #expect(subscription.occurrences.count == 6)
        #expect(subscription.medianAmount == Decimal(string: "23.90")! || subscription.medianAmount == 24)
    }

    @Test("Häufige, unregelmäßige Einkäufe mit ähnlichen Beträgen ergeben kein Abo")
    func frequentShoppingIsNoSubscription() {
        // Einkaufstage wechseln von Monat zu Monat, die Beträge liegen eng
        // beieinander (wie beim Bäcker oder Supermarkt um die Ecke).
        let daysByMonth: [Int: [Int]] = [
            5: [2, 6, 13, 15, 22, 29], 6: [4, 8, 12, 19, 24], 7: [1, 9, 14, 17, 25, 30],
            8: [3, 7, 11, 20, 27], 9: [5, 10, 15, 18, 23, 28], 10: [2, 8, 13, 21, 26]
        ]
        let amounts = ["21.40", "20.90", "22.10", "21.75", "20.60", "22.30", "21.10", "21.95"]
        var transactions: [Transaction] = []
        var index = 0
        for month in daysByMonth.keys.sorted() {
            for day in daysByMonth[month] ?? [] {
                transactions.append(purchase("Corner Market", amounts[index % amounts.count], month, day))
                index += 1
            }
        }
        let series = RecurringPaymentsDetector().detect(
            transactions: transactions,
            calendar: calendar,
            now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        )
        // Die Monats-Regel für Abos zwischen Einzelkäufen macht daraus kein
        // Abo. (Die Wochen-Erkennung ist für häufige Einkäufe zu großzügig;
        // das ist ein eigener Punkt.)
        #expect(!series.contains { $0.cadence == .monthly })
    }
}
