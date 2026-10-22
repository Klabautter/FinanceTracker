import Foundation
import Testing

@testable import FinanceTracker

@Suite("CSVParsers")
struct CSVParsersTests {
    @Test("Beträge: deutsches und englisches Format, Symbole, Vorzeichen")
    func moneyParsing() {
        #expect(CSVMoneyParser.parse("-43,27") == Decimal(string: "-43.27"))
        #expect(CSVMoneyParser.parse("985,00") == 985)
        #expect(CSVMoneyParser.parse("1.234,56") == Decimal(string: "1234.56"))
        #expect(CSVMoneyParser.parse("1,234.56") == Decimal(string: "1234.56"))
        #expect(CSVMoneyParser.parse("2850.00") == 2850)
        #expect(CSVMoneyParser.parse("43,27 €") == Decimal(string: "43.27"))
        #expect(CSVMoneyParser.parse("+5") == 5)
        #expect(CSVMoneyParser.parse("\u{2212}12,00") == -12)
        #expect(CSVMoneyParser.parse("abc") == nil)
        #expect(CSVMoneyParser.parse("") == nil)
        #expect(CSVMoneyParser.parse(nil) == nil)
    }

    @Test("Money mit Währungsspalte, Fallback greift bei Müll")
    func moneyWithCurrency() {
        let withCurrency = CSVMoneyParser.parseMoney("-5.40", currencyRaw: "usd", fallback: .eur)
        #expect(withCurrency?.currency == .usd)

        let fallback = CSVMoneyParser.parseMoney("10,00", currencyRaw: "Euro", fallback: .eur)
        #expect(fallback?.currency == .eur)
        #expect(fallback?.amount == 10)

        #expect(CSVMoneyParser.parseMoney("x", currencyRaw: nil, fallback: .eur) == nil)
    }

    @Test("Datumsformate: deutsch, ISO, mit Uhrzeit, slashes")
    func dateParsing() {
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        func day(_ date: Date?) -> DateComponents? {
            date.map { utcCalendar.dateComponents([.year, .month, .day], from: $0) }
        }

        #expect(day(CSVDateParser.parse("01.08.2026")) == DateComponents(year: 2026, month: 8, day: 1))
        #expect(day(CSVDateParser.parse("2026-08-05")) == DateComponents(year: 2026, month: 8, day: 5))
        #expect(day(CSVDateParser.parse("05/08/2026")) == DateComponents(year: 2026, month: 8, day: 5))
        #expect(day(CSVDateParser.parse("01.08.26")) == DateComponents(year: 2026, month: 8, day: 1))

        let withTime = CSVDateParser.parse("2026-08-05 14:30")
        #expect(withTime != nil)
        #expect(day(withTime)?.day == 5)

        #expect(CSVDateParser.parse("\"01.08.2026\"") != nil)
        #expect(CSVDateParser.parse("kein datum") == nil)
        #expect(CSVDateParser.parse("") == nil)
    }
}
