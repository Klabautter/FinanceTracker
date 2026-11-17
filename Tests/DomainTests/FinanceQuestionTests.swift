import Foundation
import Testing

@testable import FinanceTracker

@Suite("FinanceQuestion")
struct FinanceQuestionTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 10))! }
    private let restaurants = FinanceTracker.Category(name: "Restaurants", systemIconName: "fork.knife")
    private let groceries = FinanceTracker.Category(name: "Lebensmittel", systemIconName: "cart")

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @Test("Kategorie und Jahreszeit werden erkannt")
    func categoryAndSeason() {
        let q = FinanceQuestionParser.parse(
            "Wie viel habe ich im Sommer für Restaurants ausgegeben?",
            categories: [restaurants, groceries], merchantNames: [], now: now, calendar: calendar
        )
        #expect(q.categoryIDs == [restaurants.id])
        #expect(q.period.start == calendar.date(from: DateComponents(year: 2026, month: 6, day: 1)))
        #expect(q.period.end == calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        #expect(q.measure == .spending)
    }

    @Test("Händler und letzter Monat")
    func merchantAndLastMonth() {
        let q = FinanceQuestionParser.parse(
            "Was habe ich letzten Monat bei REWE ausgegeben",
            categories: [], merchantNames: ["REWE", "Rewe Markt Wien", "Lidl"], now: now, calendar: calendar
        )
        #expect(q.merchantKey == "rewe")
        #expect(q.period.start == calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
    }

    @Test("Monat ohne Jahr meint den letzten vergangenen; Einnahmen werden erkannt")
    func monthAndIncome() {
        let q = FinanceQuestionParser.parse(
            "Einnahmen Dezember", categories: [], merchantNames: [], now: now, calendar: calendar
        )
        #expect(q.measure == .income)
        #expect(q.period.start == calendar.date(from: DateComponents(year: 2025, month: 12, day: 1)))
    }

    @Test("Antwort summiert nur passende Ausgaben im Zeitraum")
    func answerSumsMatching() {
        func txn(_ amount: Decimal, _ day: Date, _ category: FinanceTracker.Category?) -> Transaction {
            var t = Transaction(
                accountID: UUID(), source: .demo, externalID: UUID().uuidString, status: .booked, kind: .purchase,
                amount: Money(amount: amount, currency: .eur), bookedAt: day,
                rawDescription: "X", rawMerchantName: "X", merchantDisplayName: "X"
            )
            t.categoryID = category?.id
            return t
        }
        let q = FinanceQuestionParser.parse(
            "Restaurants im Sommer", categories: [restaurants], merchantNames: [], now: now, calendar: calendar
        )
        let answer = FinanceQuestionParser.answer(
            q,
            transactions: [
                txn(-40, date(2026, 7, 3), restaurants),
                txn(-25, date(2026, 8, 20), restaurants),
                txn(-90, date(2026, 7, 4), groceries),
                txn(-30, date(2026, 10, 1), restaurants)
            ],
            baseCurrency: .eur,
            converter: CurrencyConverter()
        )
        #expect(answer.total == 65)
        #expect(answer.transactionIDs.count == 2)
    }

    @Test("Aufgeteilte Buchung: nur die Positionen der gefragten Kategorie zählen")
    func answerExpandsSplits() {
        var parent = Transaction(
            accountID: UUID(), source: .demo, externalID: "split", status: .booked, kind: .purchase,
            amount: Money(amount: -100, currency: .eur), bookedAt: date(2026, 7, 3),
            rawDescription: "X", rawMerchantName: "X", merchantDisplayName: "X"
        )
        parent.categoryID = groceries.id
        let lines = [
            TransactionSplitLine(parentTransactionID: parent.id, amount: 70, categoryID: groceries.id),
            TransactionSplitLine(parentTransactionID: parent.id, amount: 30, categoryID: restaurants.id)
        ]
        func total(_ text: String, _ categories: [FinanceTracker.Category]) -> FinanceAnswer {
            FinanceQuestionParser.answer(
                FinanceQuestionParser.parse(text, categories: categories, merchantNames: [], now: now, calendar: calendar),
                transactions: [parent], splitLines: lines, baseCurrency: .eur, converter: CurrencyConverter()
            )
        }
        #expect(total("Restaurants im Sommer", [restaurants, groceries]).total == 30)
        #expect(total("Lebensmittel im Sommer", [restaurants, groceries]).total == 70)
        // Ohne Kategorie zählt die Buchung als Ganzes, genau einmal.
        let everything = total("Ausgaben im Sommer", [])
        #expect(everything.total == 100)
        #expect(everything.transactionIDs == [parent.id])
    }
}
