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

        // Testweise günstigere Miete: der Planungsrest steigt um die Differenz.
        let cheaperRent = inputs.forecast(amounts: [rent.id: 750])
        #expect(cheaperRent.availableAmount - base.availableAmount == 150)
        // Ein ungültiger Betrag ändert nichts.
        #expect(inputs.forecast(amounts: [rent.id: 0]).availableAmount == base.availableAmount)
    }

    @Test("Reichweite im Was-wäre-wenn: weniger Monatsausgaben, turnusbereinigt")
    func scenarioChangesRunway() {
        func plan(_ name: String, _ amount: Decimal, _ cadence: RecurringCommitment.Cadence,
                  _ direction: RecurringCommitment.Direction = .expense) -> RecurringCommitment {
            RecurringCommitment(
                name: name, merchantKey: name.uppercased(), direction: direction, cadence: cadence,
                amountPolicy: .fixed, expectedAmount: amount, currency: .eur, nextExpectedDate: nil, status: .active
            )
        }
        let rent = plan("Miete", 900, .monthly)
        let insurance = plan("Versicherung", 600, .yearly)
        let salary = plan("Gehalt", 2500, .monthly, .income)
        let commitments = [rent, insurance, salary]
        let converter = CurrencyConverter()

        // Miete pausiert (−900), Versicherung auf 480 im Jahr (−10 im Monat),
        // das abgewählte Gehalt ändert die Ausgaben nicht.
        let scenario = ForecastWhatIfScenario(paused: [rent.id, salary.id], amounts: [insurance.id: 480])
        let delta = scenario.monthlySpendingDelta(commitments: commitments, baseCurrency: .eur, converter: converter)
        #expect(delta == -910)
        #expect(ForecastWhatIfScenario().isEmpty)
        #expect(ForecastWhatIfScenario().monthlySpendingDelta(commitments: commitments, baseCurrency: .eur, converter: converter) == 0)

        let runway = LiquidityRunway(
            typicalMonthlySpending: Money(amount: 2000, currency: .eur),
            typicalMonthlyNet: Money(amount: 500, currency: .eur),
            monthCount: 6,
            months: 5
        )
        let total = Money(amount: 10_000, currency: .eur)
        let changed = LiquidityCalculator.runway(runway, total: total, monthlySpendingDelta: delta)
        #expect(changed.typicalMonthlySpending.amount == 1090)
        #expect(changed.typicalMonthlyNet.amount == 1410)
        #expect(changed.months == Decimal(10_000) / Decimal(1090))
        // Fallen alle Ausgaben weg, gibt es keine endliche Reichweite.
        #expect(LiquidityCalculator.runway(runway, total: total, monthlySpendingDelta: -5000).months == nil)
    }
}
