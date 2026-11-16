import Foundation
import Testing

@testable import FinanceTracker

@Suite("ForecastWhatIf")
struct ForecastWhatIfTests {
    @Test("Ohne die offene Miete steigt der Planungsrest um genau die Miete")
    func excludingRentRaisesAvailable() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let period = DateInterval(start: start, end: calendar.date(byAdding: .month, value: 1, to: start)!)
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12))!
        let rent = RecurringCommitment(
            name: "Miete", merchantKey: "VERMIETER", direction: .expense, cadence: .monthly,
            amountPolicy: .fixed, expectedAmount: 900, currency: .eur,
            nextExpectedDate: calendar.date(from: DateComponents(year: 2026, month: 3, day: 28)), status: .active
        )
        let salary = Transaction(
            accountID: UUID(), source: .demo, externalID: "s", status: .booked, kind: .income,
            amount: Money(amount: 2500, currency: .eur),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 9)),
            rawDescription: "ACME", rawMerchantName: "ACME", merchantDisplayName: "ACME"
        )
        let inputs = ForecastInputs(
            period: period, transactions: [salary], budgets: [], budgetProgresses: [],
            commitments: [rent], explicitOccurrences: [], latestOccurrences: [:],
            baseCurrency: .eur, calendar: calendar, now: now, currencyConverter: CurrencyConverter()
        )
        let base = inputs.forecast()
        let withoutRent = inputs.forecast(excludingCommitments: [rent.id])
        #expect(withoutRent.availableAmount - base.availableAmount == 900)
    }
}
