import Foundation
import Testing

@testable import FinanceTracker

@Suite("RecurringSummaryCalculator")
struct RecurringSummaryCalculatorTests {

    private let calculator = RecurringSummaryCalculator()

    private func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    private func monthInterval(year: Int, month: Int) -> DateInterval {
        let c = calendar()
        let start = c.date(from: DateComponents(year: year, month: month, day: 1))!
        let end = c.date(byAdding: .month, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    private func commitment(
        direction: RecurringCommitment.Direction = .expense,
        cadence: RecurringCommitment.Cadence,
        amount: Decimal,
        currency: CurrencyCode = .eur,
        nextExpected: Date? = nil
    ) -> RecurringCommitment {
        RecurringCommitment(
            name: "\(cadence.rawValue)-\(direction.rawValue)",
            direction: direction,
            cadence: cadence,
            amountPolicy: .fixed,
            expectedAmount: amount,
            currency: currency,
            nextExpectedDate: nextExpected,
            status: .active
        )
    }

    @Test("Monthly 10 EUR → 10 monthly equivalent")
    func monthlyEquivalent() {
        let c = commitment(cadence: .monthly, amount: 10, nextExpected: Date())
        #expect(calculator.monthlyEquivalent(for: c) == 10)
    }

    @Test("Yearly 1200 EUR → 100 monthly equivalent")
    func yearlyNormalized() {
        let c = commitment(cadence: .yearly, amount: 1200, nextExpected: Date())
        #expect(calculator.monthlyEquivalent(for: c) == 100)
    }

    @Test("Quarterly 300 EUR → 100 monthly equivalent")
    func quarterlyNormalized() {
        let c = commitment(cadence: .quarterly, amount: 300, nextExpected: Date())
        #expect(calculator.monthlyEquivalent(for: c) == 100)
    }

    @Test("Weekly 12 EUR → 52 EUR pro Monat (×52/12)")
    func weeklyNormalized() {
        let c = commitment(cadence: .weekly, amount: 12, nextExpected: Date())
        // 12 € wöchentlich ÷ (12/52) = 52 € monatlich (Decimal-Division:
        // 12/52 ist ein repeating decimal, daher Toleranzvergleich).
        let value = calculator.monthlyEquivalent(for: c)
        let tolerance = Decimal(string: "0.0000000001")!
        #expect(abs(value - 52) < tolerance)
    }

    @Test("Due in period: monthly fällig im Monat, yearly nicht")
    func dueInPeriod() {
        let c = calendar()
        let month = monthInterval(year: 2026, month: 3)

        let monthly = commitment(
            cadence: .monthly,
            amount: 50,
            nextExpected: c.date(from: DateComponents(year: 2026, month: 3, day: 5))!
        )
        let yearly = commitment(
            cadence: .yearly,
            amount: 1200,
            nextExpected: c.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        )

        let monthlyDue = calculator.dueAmount(for: monthly, latestOccurrence: nil, in: month, calendar: c)
        #expect(monthlyDue == 50)

        let yearlyDue = calculator.dueAmount(for: yearly, latestOccurrence: nil, in: month, calendar: c)
        #expect(yearlyDue == 0)
    }

    @Test("USD-Commitment ist ausgeschlossen (keine Cross-Currency Sum)")
    func foreignCurrencyExcluded() {
        let c = calendar()
        let month = monthInterval(year: 2026, month: 3)

        let eur = commitment(
            cadence: .monthly,
            amount: 100,
            nextExpected: c.date(from: DateComponents(year: 2026, month: 3, day: 5))!
        )
        let usd = commitment(
            cadence: .monthly,
            amount: 20,
            currency: .usd,
            nextExpected: c.date(from: DateComponents(year: 2026, month: 3, day: 5))!
        )

        let summary = calculator.summary(
            commitments: [eur, usd],
            latestOccurrences: [:],
            resolutions: [:],
            period: month,
            baseCurrency: .eur,
            calendar: c
        )

        // 100 EUR + 20 USD ≠ 120 EUR: USD bleibt separat.
        #expect(summary.expenseMonthlyEquivalent == 100)
        #expect(summary.expenseDueInPeriod == 100)
        #expect(summary.foreignCurrencies.contains(.usd))
        #expect(summary.foreignExpense.first?.monthlyEquivalent == 20)
    }

    @Test("Paid im Zeitraum: offen sinkt auf 0, fällig bleibt")
    func paidSemantics() {
        let c = calendar()
        let month = monthInterval(year: 2026, month: 3)

        let a = commitment(
            cadence: .monthly,
            amount: 100,
            nextExpected: c.date(from: DateComponents(year: 2026, month: 3, day: 5))!
        )
        let b = commitment(
            cadence: .monthly,
            amount: 50,
            nextExpected: c.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        )

        // WP7 (§59): Paid-Semantik über Occurrence-Resolution.
        let summary = calculator.summary(
            commitments: [a, b],
            latestOccurrences: [:],
            resolutions: [a.id: Self.paidResolution(for: a, period: month, calendar: c)],
            period: month,
            baseCurrency: .eur,
            calendar: c
        )
        #expect(summary.expenseDueInPeriod == 150)
        #expect(summary.openDueInPeriod == 50)
    }

    /// Hilfs-Resolution: alle geplanten Vorkommen des Zeitraums gelten als
    /// bezahlt (heuristischer Match).
    static func paidResolution(
        for commitment: RecurringCommitment,
        period: DateInterval,
        calendar: Calendar
    ) -> RecurringOccurrenceResolution {
        let scheduled = RecurringScheduleService().occurrences(
            for: commitment,
            in: period,
            calendar: calendar
        ).map { date in
            ScheduledRecurringOccurrence(
                id: RecurringOccurrenceKey(commitmentID: commitment.id, scheduledDate: date, calendar: calendar),
                commitmentID: commitment.id,
                scheduledDate: date,
                expectedAmount: commitment.expectedAmount,
                currency: commitment.currency,
                matchedTransactionID: UUID(),
                matchOrigin: .heuristicMatch
            )
        }
        return RecurringOccurrenceResolution(scheduled: scheduled)
    }

    @Test("Ohne planbaren Termin: nicht als fällig, Währung gemeldet")
    func withoutPlan() {
        let c = calendar()
        let month = monthInterval(year: 2026, month: 3)

        let unplanned = commitment(cadence: .monthly, amount: 30, nextExpected: nil)

        let summary = calculator.summary(
            commitments: [unplanned],
            latestOccurrences: [:],
            resolutions: [:],
            period: month,
            baseCurrency: .eur,
            calendar: c
        )
        #expect(summary.expenseDueInPeriod == 0)
        #expect(summary.currenciesWithoutPlan == [.eur])
    }

    @Test("Latest occurrence als Plan-Seed: fällig im Folgemonat")
    func latestAsSeed() {
        let c = calendar()
        let month = monthInterval(year: 2026, month: 4)

        // Bezahlt am 20.03. → nächster Monats-Termin 20.04. → fällig im April.
        let planned = commitment(cadence: .monthly, amount: 40, nextExpected: nil)
        let latest = c.date(from: DateComponents(year: 2026, month: 3, day: 20))!

        let due = calculator.dueAmount(
            for: planned,
            latestOccurrence: latest,
            in: month,
            calendar: c
        )
        #expect(due == 40)
    }

    @Test("Income: monatlich und fällig getrennt (Ø-Label-Semantik)")
    func incomeSemantics() {
        let c = calendar()
        let month = monthInterval(year: 2026, month: 3)

        let salary = RecurringCommitment(
            name: "Gehalt",
            direction: .income,
            cadence: .monthly,
            amountPolicy: .fixed,
            expectedAmount: 2850,
            currency: .eur,
            nextExpectedDate: c.date(from: DateComponents(year: 2026, month: 3, day: 28))!,
            status: .active
        )
        let bonus = RecurringCommitment(
            name: "Bonus",
            direction: .income,
            cadence: .yearly,
            amountPolicy: .fixed,
            expectedAmount: 12000,
            currency: .eur,
            nextExpectedDate: c.date(from: DateComponents(year: 2026, month: 11, day: 30))!,
            status: .active
        )

        let summary = calculator.summary(
            commitments: [salary, bonus],
            latestOccurrences: [:],
            resolutions: [:],
            period: month,
            baseCurrency: .eur,
            calendar: c
        )
        // Ø monatlich: 2850 + 12000/12 = 3850: Label sagt „Ø monatlich“.
        #expect(summary.incomeMonthlyEquivalent == 3850)
        // Fällig im März: nur das Gehalt (Bonus ist im November).
        #expect(summary.incomeDueInPeriod == 2850)
    }

    @Test("Paused Commitments fließen nicht in die Summen")
    func pausedExcluded() {
        let c = calendar()
        let month = monthInterval(year: 2026, month: 3)

        var paused = commitment(
            cadence: .monthly,
            amount: 100,
            nextExpected: c.date(from: DateComponents(year: 2026, month: 3, day: 5))!
        )
        paused.status = .paused

        let summary = calculator.summary(
            commitments: [paused],
            latestOccurrences: [:],
            resolutions: [:],
            period: month,
            baseCurrency: .eur,
            calendar: c
        )
        #expect(summary.expenseMonthlyEquivalent == 0)
        #expect(summary.expenseDueInPeriod == 0)
    }
}

@MainActor
@Suite("FixkostenModelSummary")
struct FixkostenModelSummaryTests {

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    @Test("Model-Summary nutzt Cadence-Normalisierung und Currency-Separation")
    func modelSummary() async throws {
        let dependencies = try makeDependencies()
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        // Deterministisch innerhalb des aktuellen Monats: "now + 3 Tage"
        // fällt am Monatsende in den Folgemonat und würde die Periode
        // verlassen (flaky). Stattdessen fester Tag im Monatsersten-Interval.
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let inMonth = calendar.date(byAdding: .day, value: 3, to: monthStart)!

        try await dependencies.recurringCommitmentRepository.upsert([
            RecurringCommitment(
                name: "Miete",
                direction: .expense,
                cadence: .monthly,
                amountPolicy: .fixed,
                expectedAmount: 985,
                currency: .eur,
                nextExpectedDate: inMonth,
                status: .active
            ),
            RecurringCommitment(
                name: "Versicherung",
                direction: .expense,
                cadence: .yearly,
                amountPolicy: .fixed,
                expectedAmount: 1200,
                currency: .eur,
                nextExpectedDate: calendar.date(byAdding: .month, value: 5, to: now),
                status: .active
            ),
            RecurringCommitment(
                name: "US-Abo",
                direction: .expense,
                cadence: .monthly,
                amountPolicy: .fixed,
                expectedAmount: 10,
                currency: .usd,
                nextExpectedDate: inMonth,
                status: .active
            )
        ])

        let model = FixkostenModel(dependencies: dependencies)
        await model.load()

        // Ø monatlich: 985 (Miete) + 100 (Versicherung/12) = 1085: US-Abo
        // bleibt separat (keine Cross-Currency Summe).
        #expect(model.monthlyTotal == 1085)
        #expect(model.summary.foreignCurrencies.contains(.usd))
        // Fällig in dieser Periode: nur Miete (Versicherung erst in 5 Monaten).
        #expect(model.dueInPeriodTotal == 985)
        #expect(model.openTotal == 985)
    }
}
