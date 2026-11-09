import Foundation
import Testing

@testable import FinanceTracker

@Suite("Kontostand aus Kopfzeilen eines Auszugs")
struct StatementBalanceExtractorTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private func endOfDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day + 1))!.addingTimeInterval(-1)
    }

    @Test("Anfangs- und Endstand: der jüngste zählt, zum Ende des Tages")
    func openingAndClosing() throws {
        let balance = try #require(StatementBalanceExtractor.closingBalance(in: [
            "Kontoauszug",
            "Zeitraum 01.09.2026 - 30.09.2026",
            "Kontostand am 01.09.2026 2.410,53 EUR",
            "Kontostand am 30.09.2026 2.415,65 EUR",
            "01.09.2026 31.08.2026 Erhaltene Zinsen +5,12 EUR"
        ], currency: .eur, calendar: calendar))
        #expect(balance.amount == Money(amount: Decimal(string: "2415.65")!, currency: .eur))
        #expect(balance.asOf == endOfDay(2026, 9, 30))
        #expect(balance.source == .file)
    }

    @Test("Weitere Schreibweisen: Neuer Saldo, nachgestelltes Minus, Englisch")
    func variants() {
        #expect(StatementBalanceExtractor.closingBalance(
            in: ["Alter Saldo per 31.08.26 100,00", "Neuer Saldo per 30.09.26 1.234,56-"],
            currency: .eur, calendar: calendar
        )?.amount.amount == Decimal(string: "-1234.56")!)
        #expect(StatementBalanceExtractor.closingBalance(
            in: ["Opening balance on 01/09/2026 £900.00", "Closing balance on 30/09/2026 £1,250.40"],
            currency: .gbp, calendar: calendar
        )?.amount.amount == Decimal(string: "1250.40")!)
        #expect(StatementBalanceExtractor.closingBalance(
            in: ["Ending balance as of 2026-09-30: 3,000.00 USD"],
            currency: .usd, calendar: calendar
        )?.amount.amount == 3000)
    }

    @Test("Buchungszeilen, verfügbarer Betrag und Stand ohne Datum zählen nicht")
    func ignoredLines() {
        #expect(StatementBalanceExtractor.closingBalance(in: [
            "15.09.2026 Saldo Kreditkarte -120,00",
            "Verfügbarer Saldo am 30.09.2026 5.000,00 EUR",
            "Kontostand 1.000,00 EUR"
        ], currency: .eur, calendar: calendar) == nil)
    }

    @Test("Endstand ohne Datum gilt zum Ende des Auszugszeitraums")
    func undatedClosingBalanceUsesPeriodEnd() throws {
        let balance = try #require(StatementBalanceExtractor.closingBalance(in: [
            "Kreditkartenabrechnung",
            "Abrechnungszeitraum 01.09.2026 - 30.09.2026",
            "01.09.2026 Alter Saldo 980,00 EUR",
            "15.09.2026 REWE -43,27 EUR",
            "Neuer Saldo 1.234,56 EUR"
        ], currency: .eur, calendar: calendar))
        #expect(balance.amount == Money(amount: Decimal(string: "1234.56")!, currency: .eur))
        #expect(balance.asOf == endOfDay(2026, 9, 30))

        let english = try #require(StatementBalanceExtractor.closingBalance(in: [
            "Statement period 01/09/2026 to 30/09/2026",
            "Closing balance £1,250.40"
        ], currency: .gbp, calendar: calendar))
        #expect(english.amount.amount == Decimal(string: "1250.40")!)
        #expect(english.asOf == endOfDay(2026, 9, 30))
    }

    @Test("Endstand ohne Datum: ohne eindeutigen Zeitraum oder bei mehreren Beträgen kein Stand")
    func undatedClosingBalanceNeedsUnambiguousPeriod() {
        // Kein Zeitraum.
        #expect(StatementBalanceExtractor.closingBalance(
            in: ["Neuer Saldo 1.234,56 EUR"], currency: .eur, calendar: calendar
        ) == nil)
        // Zwei verschiedene Zeiträume.
        #expect(StatementBalanceExtractor.closingBalance(in: [
            "Zeitraum 01.08.2026 - 31.08.2026", "Zeitraum 01.09.2026 - 30.09.2026", "Endsaldo 500,00 EUR"
        ], currency: .eur, calendar: calendar) == nil)
        // Zwei verschiedene Endstände ohne Datum.
        #expect(StatementBalanceExtractor.closingBalance(in: [
            "Zeitraum 01.09.2026 - 30.09.2026", "Endsaldo 500,00 EUR", "Endsaldo 600,00 EUR"
        ], currency: .eur, calendar: calendar) == nil)
        // Ein Stand mit Datum hat Vorrang vor einem ohne.
        #expect(StatementBalanceExtractor.closingBalance(in: [
            "Zeitraum 01.09.2026 - 30.09.2026", "Kontostand am 30.09.2026 700,00 EUR", "Endsaldo 500,00 EUR"
        ], currency: .eur, calendar: calendar)?.amount.amount == 700)
        // Ein Anfangsstand ohne Datum ist kein Endstand.
        #expect(StatementBalanceExtractor.closingBalance(in: [
            "Zeitraum 01.09.2026 - 30.09.2026", "Alter Saldo 500,00 EUR"
        ], currency: .eur, calendar: calendar) == nil)
    }

    @Test("Stand in anderer Währung behält seine Währung")
    func keepsStatedCurrency() {
        let balance = StatementBalanceExtractor.closingBalance(
            in: ["Kontostand am 30.09.2026 1.000,00 USD"],
            currency: .eur, calendar: calendar
        )
        #expect(balance?.amount == Money(amount: 1000, currency: .usd))
        #expect(StatementBalanceExtractor.closingBalance(
            in: ["Closing balance on 30/09/2026 1,000.00 USD 900.00 EUR"],
            currency: .eur, calendar: calendar
        ) == nil)
    }

    @Test("Monatsnamen auf Englisch und Deutsch")
    func monthNames() {
        let english = StatementBalanceExtractor.closingBalance(
            in: ["Opening balance $0.00 at start of 1 May 2026", "Closing balance $1,375.17 at end of 31 Oct 2026"],
            currency: .usd, calendar: calendar
        )
        #expect(english?.amount == Money(amount: Decimal(string: "1375.17")!, currency: .usd))
        #expect(english?.asOf == endOfDay(2026, 10, 31))
        let german = StatementBalanceExtractor.closingBalance(
            in: ["Kontostand am 30. September 2026 812,40 €", "Kontostand am 1. März 2026 700,00 €"],
            currency: .eur, calendar: calendar
        )
        #expect(german?.amount.amount == Decimal(string: "812.40")!)
        #expect(german?.asOf == endOfDay(2026, 9, 30))
    }

    @Test("Verschiedene Beträge für denselben Tag ergeben keinen Stand")
    func ambiguous() {
        #expect(StatementBalanceExtractor.closingBalance(in: [
            "Kontostand am 30.09.2026 1.000,00 EUR",
            "Saldo am 30.09.2026 1.200,00 EUR"
        ], currency: .eur, calendar: calendar) == nil)
    }
}
