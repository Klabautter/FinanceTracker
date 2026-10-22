import Foundation
import Testing

@testable import FinanceTracker

@Suite("MoneyPresentation")
struct MoneyPresentationTests {

    private static let deDE = Locale(identifier: "de_DE")
    private static let deAT = Locale(identifier: "de_AT")
    private static let enUS = Locale(identifier: "en_US")

    private func digits(_ string: String) -> String {
        string.filter { $0.isNumber || $0 == "." || $0 == "," }
    }

    @Test("Positive EUR-Beträge in de_DE/de_AT/en_US")
    func positiveEUR() {
        let money = Money(amount: Decimal(string: "1234.56")!, currency: .eur)

        let de = digits(MoneyFormatter.string(money, locale: Self.deDE))
        #expect(de.hasPrefix("1.234,56") || de.hasPrefix("1234,56"))
        #expect(MoneyFormatter.string(money, locale: Self.deDE).contains("€"))

        let at = digits(MoneyFormatter.string(money, locale: Self.deAT))
        #expect(at.hasPrefix("1.234,56") || at.hasPrefix("1234,56"))

        let us = digits(MoneyFormatter.string(money, locale: Self.enUS))
        #expect(us.hasPrefix("1,234.56") || us.hasPrefix("1234.56"))
    }

    @Test("USD-Beträge über Locales hinweg")
    func usd() {
        let money = Money(amount: Decimal(string: "99.90")!, currency: .usd)

        let de = MoneyFormatter.string(money, locale: Self.deDE)
        #expect(digits(de).hasPrefix("99,90") || digits(de).hasPrefix("99.9"))
        #expect(de.contains("US$") || de.contains("$"))

        let us = MoneyFormatter.string(money, locale: Self.enUS)
        #expect(us.contains("$"))
        #expect(digits(us).hasPrefix("99.90"))
    }

    @Test("Signed: positiv mit Plus, negativ unverändert")
    func signed() {
        let positive = Money(amount: Decimal(string: "10.00")!, currency: .eur)
        let negative = Money(amount: Decimal(string: "-10.00")!, currency: .eur)

        #expect(MoneyFormatter.signed(positive, locale: Self.deDE).hasPrefix("+"))
        #expect(!MoneyFormatter.signed(negative, locale: Self.deDE).hasPrefix("++"))
        #expect(MoneyFormatter.signed(negative, locale: Self.deDE).contains("-"))
    }

    @Test("Null-Betrag formatiert")
    func zero() {
        let zero = Money(amount: 0, currency: .eur)
        let formatted = MoneyFormatter.string(zero, locale: Self.deDE)
        #expect(digits(formatted).hasPrefix("0,00") || digits(formatted).hasPrefix("0.00"))
    }

    @Test("Großer Betrag mit Gruppentrennern")
    func largeAmount() {
        let large = Money(amount: Decimal(string: "1234567.89")!, currency: .eur)
        let de = MoneyFormatter.string(large, locale: Self.deDE)
        #expect(de.contains(".") || de.contains("'") || de.contains(" "))
        #expect(digits(de).contains("1234567") || digits(de).hasPrefix("1.234.567,89") || digits(de).hasPrefix("1234567,89"))

        let us = digits(MoneyFormatter.string(large, locale: Self.enUS))
        #expect(us.hasPrefix("1,234,567.89") || us.hasPrefix("1234567.89"))
    }

    @Test("Formatierung ist nicht an den MainActor gebunden")
    func offMainActor() async {
        let money = Money(amount: Decimal(string: "5.00")!, currency: .eur)
        let formatted = await Task.detached {
            MoneyFormatter.string(money, locale: Locale(identifier: "de_DE"))
        }.value
        #expect(!formatted.isEmpty)
    }
}

@Suite("DatePresentation")
struct DatePresentationTests {

    private static let deDE = Locale(identifier: "de_DE")
    private static let enUS = Locale(identifier: "en_US")

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar.date(from: components)!
    }

    @Test("day zeigt Tag, Monat und Jahr")
    func day() {
        let date = Self.date(2026, 8, 26)
        let de = AppDateFormatter.day(date, locale: Self.deDE)
        #expect(de.contains("26"))
        #expect(de.contains("2026") || de.contains("08."))

        let us = AppDateFormatter.day(date, locale: Self.enUS)
        #expect(us.contains("26"))
    }

    @Test("weekdayDay enthält Wochentag-Kürzel")
    func weekdayDay() {
        let date = Self.date(2026, 8, 26) // Mittwoch
        let de = AppDateFormatter.weekdayDay(date, locale: Self.deDE)
        #expect(de.lowercased().hasPrefix("mi."))
        #expect(de.contains("26"))

        let us = AppDateFormatter.weekdayDay(date, locale: Self.enUS)
        #expect(us.lowercased().contains("wed"))
    }

    @Test("monthYear enthält Monatsname und Jahr")
    func monthYear() {
        let date = Self.date(2026, 2, 15)
        let de = AppDateFormatter.monthYear(date, locale: Self.deDE)
        #expect(de.contains("2026"))
        #expect(de.lowercased().contains("februar") || de.lowercased().contains("febr"))

        let us = AppDateFormatter.monthYear(date, locale: Self.enUS)
        #expect(us.lowercased().contains("february"))
        #expect(us.contains("2026"))
    }

    @Test("Datum-Darstellung ist nicht an den MainActor gebunden")
    func offMainActor() async {
        let date = Self.date(2026, 8, 26)
        let formatted = await Task.detached {
            AppDateFormatter.day(date, locale: Self.deDE)
        }.value
        #expect(!formatted.isEmpty)
    }
}
