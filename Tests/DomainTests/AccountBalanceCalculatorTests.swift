import Foundation
import Testing

@testable import FinanceTracker

@Suite("AccountBalanceCalculator")
struct AccountBalanceCalculatorTests {
    private let calendar = Calendar(identifier: .gregorian)
    private func day(_ iso: String, hour: Int = 12) -> Date {
        var components = DateComponents()
        let parts = iso.split(separator: "-").map { Int($0)! }
        components.year = parts[0]; components.month = parts[1]; components.day = parts[2]; components.hour = hour
        return calendar.date(from: components)!
    }

    @Test("Ohne Anfangsbestand gibt es keinen Stand")
    func noOpeningBalanceMeansNoBalance() {
        let movements = [AccountBalanceCalculator.Movement(date: day("2026-10-05"), amount: -10)]
        #expect(AccountBalanceCalculator.balance(openingBalance: nil, openingDate: day("2026-10-01"), movements: movements, calendar: calendar) == nil)
    }

    @Test("Bewegungen vor dem Stichtag stecken im Anfangsbestand, ab Tagesbeginn zählen sie")
    func movementsBeforeOpeningDateAreIgnored() {
        let movements = [
            AccountBalanceCalculator.Movement(date: day("2026-09-30"), amount: -50),
            AccountBalanceCalculator.Movement(date: day("2026-10-01", hour: 0), amount: -10),
            AccountBalanceCalculator.Movement(date: day("2026-10-01", hour: 9), amount: -5),
            AccountBalanceCalculator.Movement(date: day("2026-10-07"), amount: 20)
        ]
        let balance = AccountBalanceCalculator.balance(openingBalance: 100, openingDate: day("2026-10-01"), movements: movements, calendar: calendar)
        #expect(balance == 105)
    }

    @Test("Ohne Stichtag zählen alle Bewegungen")
    func noDateCountsEverything() {
        let movements = [
            AccountBalanceCalculator.Movement(date: day("2020-01-01"), amount: -1),
            AccountBalanceCalculator.Movement(date: day("2026-10-07"), amount: -2)
        ]
        #expect(AccountBalanceCalculator.balance(openingBalance: 10, openingDate: nil, movements: movements, calendar: calendar) == 7)
    }

    @Test("Anfangsbestand ohne Bewegungen ist der Stand; negative Stände sind erlaubt")
    func openingOnlyAndNegative() {
        #expect(AccountBalanceCalculator.balance(openingBalance: Decimal(string: "12.50"), openingDate: day("2026-10-01"), movements: [], calendar: calendar) == Decimal(string: "12.50"))
        let movements = [AccountBalanceCalculator.Movement(date: day("2026-10-02"), amount: -20)]
        #expect(AccountBalanceCalculator.balance(openingBalance: 5, openingDate: day("2026-10-01"), movements: movements, calendar: calendar) == -15)
    }
}
