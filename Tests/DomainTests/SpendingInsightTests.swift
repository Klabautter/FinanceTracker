import Foundation
import Testing

@testable import FinanceTracker

@Suite("SpendingInsights")
struct SpendingInsightTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()
    private let account = UUID()

    private func date(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 10))!
    }

    private func expense(_ merchant: String, _ amount: Decimal, _ date: Date) -> Transaction {
        Transaction(
            accountID: account, source: .demo, externalID: UUID().uuidString, status: .booked, kind: .purchase,
            amount: Money(amount: -amount, currency: .eur), bookedAt: date,
            rawDescription: merchant, rawMerchantName: merchant, merchantDisplayName: merchant
        )
    }

    @Test("Zwei gleiche Abbuchungen beim selben Händler innerhalb von zwei Tagen")
    func duplicateCharge() {
        let insights = SpendingInsightDetector().detect(
            transactions: [expense("FITNESS STUDIO", 39.90, date(11, 3)), expense("FITNESS STUDIO", 39.90, date(11, 4))],
            commitments: [], budgetProgresses: [], now: date(11, 16), calendar: calendar
        )
        #expect(insights.map(\.kind) == [.possibleDuplicate])
    }

    @Test("Abo wurde teurer")
    func priceIncrease() {
        let netflix = RecurringCommitment(
            name: "Netflix", merchantKey: "NETFLIX", direction: .expense, cadence: .monthly,
            amountPolicy: .fixed, expectedAmount: Decimal(string: "13.99")!, currency: .eur, status: .active
        )
        let insights = SpendingInsightDetector().detect(
            transactions: [expense("NETFLIX", Decimal(string: "13.99")!, date(9, 14)),
                           expense("NETFLIX", Decimal(string: "13.99")!, date(10, 14)),
                           expense("NETFLIX", Decimal(string: "14.99")!, date(11, 14))],
            commitments: [netflix], budgetProgresses: [], now: date(11, 16), calendar: calendar
        )
        #expect(insights.contains { $0.kind == .subscriptionPriceIncrease })
    }

    @Test("Ungewöhnlich hoher Betrag bei bekanntem Händler, normale Einkäufe nicht")
    func unusuallyHigh() {
        var rows = (1...6).map { expense("REWE", 30, date(8, $0 * 3)) }
        rows.append(expense("REWE", 32, date(11, 10)))
        rows.append(expense("REWE", 180, date(11, 12)))
        let insights = SpendingInsightDetector().detect(
            transactions: rows, commitments: [], budgetProgresses: [], now: date(11, 16), calendar: calendar
        )
        #expect(insights.filter { $0.kind == .unusuallyHigh }.count == 1)
    }

    @Test("Budget läuft beim aktuellen Tempo vor Periodenende leer")
    func budgetRunsOut() {
        let budget = Budget(name: "Lebensmittel", amount: 300, categoryIDs: [])
        let period = DateInterval(start: date(11, 1), end: date(12, 1))
        // Krummer Betrag wie im echten Leben (lange Dezimalbrüche beim Teilen).
        let fast = BudgetProgress(budget: budget, spent: Decimal(string: "240.07")!, currency: .eur, period: period)
        let calm = BudgetProgress(budget: Budget(name: "Kino", amount: 300, categoryIDs: []), spent: 60, currency: .eur, period: period)
        let insights = SpendingInsightDetector().detect(
            transactions: [], commitments: [], budgetProgresses: [fast, calm], now: date(11, 16), calendar: calendar
        )
        #expect(insights.map(\.kind) == [.budgetRunsOut])
        #expect(insights.first?.title.contains("Lebensmittel") == true)
    }

    @Test("Nichts Auffälliges ergibt keine Hinweise")
    func quietMonth() {
        let rows = (1...5).map { expense("BÄCKER", 4, date(11, $0 * 3)) }
        let insights = SpendingInsightDetector().detect(
            transactions: rows, commitments: [], budgetProgresses: [], now: date(11, 16), calendar: calendar
        )
        #expect(insights.isEmpty)
    }
}
