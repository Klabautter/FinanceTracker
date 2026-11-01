import Foundation
import Testing

@testable import FinanceTracker

@Suite("Gesamtstand und Reichweite")
struct LiquidityCalculatorTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func summary(
        _ name: String,
        balance: Decimal?,
        currency: CurrencyCode = .eur,
        reportedAt: Date? = nil,
        isActive: Bool = true
    ) -> AccountSummary {
        AccountSummary(
            account: Account(name: name, type: .checking, currency: currency, source: .manual, isActive: isActive),
            netMovement: Money(amount: 0, currency: currency),
            balance: balance.map { Money(amount: $0, currency: currency) },
            balanceBasis: balance == nil ? nil : (reportedAt == nil ? .openingBalance : .reported(.bank)),
            balanceReportedAt: reportedAt,
            foreignCurrencies: [],
            transactionCount: 0
        )
    }

    @Test("Gemeldeter Stand plus nur spätere Bewegungen")
    func reportedBalancePlusLaterMovements() {
        let asOf = date(2026, 10, 20, hour: 12)
        let account = Account(
            name: "Giro", type: .checking, currency: .eur, source: .openBanking,
            openingBalance: 999,
            reportedBalance: ReportedBalance(amount: Money(amount: 1000, currency: .eur), asOf: asOf, source: .bank)
        )
        let result = AccountBalanceCalculator.balance(for: account, movements: [
            .init(date: date(2026, 10, 19), amount: -50),
            .init(date: asOf, amount: -20),
            .init(date: date(2026, 10, 21), amount: -30),
            .init(date: date(2026, 10, 22), amount: 5)
        ], calendar: calendar)
        // Der gemeldete Stand hat Vorrang vor dem Anfangsbestand.
        #expect(result == .init(amount: 975, basis: .reported(.bank), reportedAt: asOf))
    }

    @Test("Stand in fremder Währung wird nicht verrechnet, dann zählt der Anfangsbestand")
    func reportedBalanceInOtherCurrencyIsIgnored() {
        let account = Account(
            name: "Karte", type: .creditCard, currency: .eur, source: .csvImport,
            openingBalance: 100, openingBalanceDate: date(2026, 10, 1),
            reportedBalance: ReportedBalance(amount: Money(amount: 50, currency: .usd), asOf: date(2026, 10, 10), source: .file)
        )
        let result = AccountBalanceCalculator.balance(for: account, movements: [.init(date: date(2026, 10, 5), amount: -10)], calendar: calendar)
        #expect(result == .init(amount: 90, basis: .openingBalance, reportedAt: nil))
    }

    @Test("Ohne gemeldeten Stand und Anfangsbestand gibt es keinen Stand")
    func noBalance() {
        let account = Account(name: "Karte", type: .creditCard, currency: .eur, source: .csvImport)
        #expect(AccountBalanceCalculator.balance(for: account, movements: [.init(date: Date(), amount: -10)]) == nil)
    }

    @Test("Summe in Basiswährung, Fremdwährung umgerechnet, fehlende Stände und Kurse gemeldet")
    func overviewConvertsAndReports() {
        let converter = CurrencyConverter(eurPerUnit: [.usd: Decimal(string: "0.9")!])
        let calculator = LiquidityCalculator(baseCurrency: .eur, converter: converter)
        let overview = calculator.overview(of: [
            summary("Giro", balance: 3000),
            summary("Karte", balance: -500),
            summary("USD", balance: 1000, currency: .usd),
            summary("Bargeld", balance: nil),
            summary("Franken", balance: 100, currency: CurrencyCode("XYZ")),
            summary("Getrennt", balance: 10_000, isActive: false)
        ])
        #expect(overview.total == Money(amount: 3400, currency: .eur))
        #expect(overview.shares.map(\.summary.account.name) == ["Giro", "USD", "Karte"])
        #expect(overview.usesConversion)
        #expect(overview.withoutBalance.map(\.account.name) == ["Bargeld"])
        #expect(overview.unconvertible.map(\.account.name) == ["Franken"])
        // Anteile nur am Guthaben: die Kartenschuld hat keinen Anteil.
        let fractions = overview.shares.map(\.fraction)
        #expect(abs(fractions[0] - 3000.0 / 3900.0) < 0.0001)
        #expect(abs(fractions[1] - 900.0 / 3900.0) < 0.0001)
        #expect(fractions[2] == 0)
    }

    @Test("Ältester gemeldeter Stand")
    func oldestReported() {
        let calculator = LiquidityCalculator(baseCurrency: .eur, converter: CurrencyConverter())
        let older = date(2026, 10, 1)
        let overview = calculator.overview(of: [
            summary("A", balance: 1, reportedAt: date(2026, 10, 20)),
            summary("B", balance: 1, reportedAt: older),
            summary("C", balance: 1)
        ])
        #expect(overview.oldestReportedAt == older)
    }

    @Test("Reichweite: Mittel der vollen Monate mit Buchungen, laufender Monat zählt nicht")
    func runwayAveragesFullMonths() throws {
        let calculator = LiquidityCalculator(baseCurrency: .eur, converter: CurrencyConverter())
        let points = [
            MonthlyCashflowPoint(monthStart: date(2026, 6, 1), income: 0, spending: 0),
            MonthlyCashflowPoint(monthStart: date(2026, 7, 1), income: 3000, spending: 2000),
            MonthlyCashflowPoint(monthStart: date(2026, 8, 1), income: 3000, spending: 2500),
            MonthlyCashflowPoint(monthStart: date(2026, 9, 1), income: 3000, spending: 1500),
            MonthlyCashflowPoint(monthStart: date(2026, 10, 1), income: 0, spending: 9000)
        ]
        let runway = try #require(calculator.runway(
            total: Money(amount: 8000, currency: .eur),
            monthlyPoints: points,
            now: date(2026, 10, 15),
            calendar: calendar
        ))
        #expect(runway.monthCount == 3)
        #expect(runway.averageMonthlySpending == Money(amount: 2000, currency: .eur))
        #expect(runway.averageMonthlyNet == Money(amount: 1000, currency: .eur))
        #expect(runway.months == 4)
    }

    @Test("Ohne volle Monate keine Reichweite; ohne Ausgaben keine Monatszahl")
    func runwayEdgeCases() {
        let calculator = LiquidityCalculator(baseCurrency: .eur, converter: CurrencyConverter())
        let now = date(2026, 10, 15)
        #expect(calculator.runway(
            total: Money(amount: 100, currency: .eur),
            monthlyPoints: [MonthlyCashflowPoint(monthStart: date(2026, 10, 1), income: 0, spending: 50)],
            now: now,
            calendar: calendar
        ) == nil)
        let incomeOnly = calculator.runway(
            total: Money(amount: 100, currency: .eur),
            monthlyPoints: [MonthlyCashflowPoint(monthStart: date(2026, 9, 1), income: 500, spending: 0)],
            now: now,
            calendar: calendar
        )
        #expect(incomeOnly?.months == nil)
        #expect(incomeOnly?.averageMonthlyNet == Money(amount: 500, currency: .eur))
    }
}
