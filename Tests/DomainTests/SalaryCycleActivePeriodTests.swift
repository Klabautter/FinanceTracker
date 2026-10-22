import Foundation
import Testing

@testable import FinanceTracker

/// WP6 (§49): Salary-Cycle-Semantik: AKTIVER Zeitraum des Nutzers,
/// nicht der historisch abgeschlossene Zyklus.
@Suite("SalaryCycleActivePeriod")
struct SalaryCycleActivePeriodTests {

    private let calendar = Calendar(identifier: .gregorian)
    private let timezone = TimeZone(identifier: "Europe/Berlin")!

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        makeCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func income(cadence: RecurringCommitment.Cadence = .monthly) -> RecurringCommitment {
        RecurringCommitment(
            name: "Gehalt Acme",
            merchantKey: "GEHALT ACME",
            direction: .income,
            cadence: cadence,
            amountPolicy: .fixed,
            expectedAmount: 2000,
            currency: .eur,
            nextExpectedDate: nil,
            status: .active
        )
    }

    private func salaryTransaction(on date: Date) -> Transaction {
        Transaction(
            accountID: UUID(),
            source: .manual,
            kind: .income,
            amount: Money(amount: 2000, currency: .eur),
            bookedAt: date,
            rawDescription: "Gehalt Acme GmbH",
            merchantDisplayName: "Gehalt Acme GmbH"
        )
    }

    private func interval(
        commitment: RecurringCommitment? = nil,
        containing reference: Date,
        payments: [Date],
        cadence: RecurringCommitment.Cadence = .monthly
    ) throws -> DateInterval {
        let commitment = commitment ?? income(cadence: cadence)
        let budget = Budget(
            name: "Gehalts-Budget",
            amount: 300,
            currency: .eur,
            periodPolicy: .salaryCycle(recurringIncomeID: commitment.id)
        )
        return try BudgetPeriodResolver().interval(
            for: budget,
            containing: reference,
            calendar: makeCalendar(),
            recurringCommitments: [commitment],
            transactions: payments.map { salaryTransaction(on: $0) }
        )
    }

    @Test("Letzte Zahlung 28.07., Referenz 15.08. → aktiver Zyklus [28.07., 28.08.)")
    func activeCycleBetweenPayments() throws {
        let interval = try interval(
            containing: date(2026, 8, 15),
            payments: [date(2026, 6, 28), date(2026, 7, 28)]
        )
        #expect(interval.start == date(2026, 7, 28))
        #expect(interval.end == date(2026, 8, 28))
        // §209: Der angefragte Zeitpunkt liegt WIRKLICH im Intervall.
        #expect(interval.contains(date(2026, 8, 15)))
    }

    @Test("Reale Zahlung 28.08. vorhanden, Referenz 29.08. → [28.08., 28.09.)")
    func newPaymentStartsNextCycle() throws {
        let interval = try interval(
            containing: date(2026, 8, 29),
            payments: [date(2026, 7, 28), date(2026, 8, 28)]
        )
        #expect(interval.start == date(2026, 8, 28))
        #expect(interval.end == date(2026, 9, 28))
        #expect(interval.contains(date(2026, 8, 29)))
    }

    @Test("Eine historische Zahlung genügt: Schedule-basiertes Ende (§45)")
    func singlePaymentUsesScheduleEnd() throws {
        let interval = try interval(
            containing: date(2026, 8, 15),
            payments: [date(2026, 7, 28)]
        )
        #expect(interval.start == date(2026, 7, 28))
        #expect(interval.end == date(2026, 8, 28))
        #expect(interval.contains(date(2026, 8, 15)))
    }

    @Test("Irreguläre reale nächste Zahlung schlägt die Prognose (actual wins)")
    func actualNextPaymentWins() throws {
        // Zahlung am 25.08. (vorzeitig statt 28.08.), die Referenz vom
        // 20.08. liegt noch im alten Zyklus, der von der REALen Zahlung
        // geschlossen wird.
        let interval = try interval(
            containing: date(2026, 8, 20),
            payments: [date(2026, 7, 28), date(2026, 8, 25)]
        )
        #expect(interval.start == date(2026, 7, 28))
        #expect(interval.end == date(2026, 8, 25))
        #expect(interval.contains(date(2026, 8, 20)))
    }

    @Test("Referenz vor der nächsten Zahlung → aktueller Zyklus bleibt")
    func referenceBeforeNextPaymentKeepsCurrentCycle() throws {
        let interval = try interval(
            containing: date(2026, 8, 10),
            payments: [date(2026, 7, 28)]
        )
        #expect(interval.start == date(2026, 7, 28))
        #expect(interval.end == date(2026, 8, 28))
    }

    @Test("Keine Zahlung vor der Referenz → insufficientSalaryHistory")
    func noPaymentBeforeReferenceThrows() {
        let commitment = income()
        do {
            _ = try interval(
                commitment: commitment,
                containing: date(2026, 8, 10),
                payments: [date(2026, 9, 28)] // nur zukünftige Zahlung
            )
            Issue.record("Erwartete insufficientSalaryHistory")
        } catch let error as BudgetPeriodResolverError {
            #expect(error == .insufficientSalaryHistory(incomeID: commitment.id))
        } catch {
            Issue.record("Falscher Fehlertyp: \(error)")
        }
    }

    @Test("Fehlendes Income-Commitment → missingSalaryCommitment")
    func missingCommitmentThrows() {
        let budget = Budget(
            name: "Gehalts-Budget",
            amount: 300,
            currency: .eur,
            periodPolicy: .salaryCycle(recurringIncomeID: UUID())
        )
        do {
            _ = try BudgetPeriodResolver().interval(
                for: budget,
                containing: date(2026, 8, 15),
                calendar: makeCalendar(),
                recurringCommitments: [],
                transactions: [salaryTransaction(on: date(2026, 7, 28))]
            )
            Issue.record("Erwartete missingSalaryCommitment")
        } catch let error as BudgetPeriodResolverError {
            #expect(error == .missingSalaryCommitment(incomeID: budget.periodPolicy.periodPolicySalaryIncomeID!))
        } catch {
            Issue.record("Falscher Fehlertyp: \(error)")
        }
    }

    @Test("Vorperiode: [Vorletzte Zahlung, Letzte Zahlung) rückwärts")
    func previousIntervalSemantics() throws {
        let commitment = income()
        let budget = Budget(
            name: "Gehalts-Budget",
            amount: 300,
            currency: .eur,
            periodPolicy: .salaryCycle(recurringIncomeID: commitment.id)
        )
        let previous = try BudgetPeriodResolver().previousInterval(
            for: budget,
            containing: date(2026, 8, 29),
            calendar: makeCalendar(),
            recurringCommitments: [commitment],
            transactions: [
                salaryTransaction(on: date(2026, 6, 28)),
                salaryTransaction(on: date(2026, 7, 28)),
                salaryTransaction(on: date(2026, 8, 28))
            ]
        )
        #expect(previous.start == date(2026, 7, 28))
        #expect(previous.end == date(2026, 8, 28))
    }

    // MARK: - Overview == Detail (§46/§48)

    @Test("BudgetProgress trägt die Resolver-Periode: Overview und Detail identisch")
    func progressCarriesResolvedPeriod() throws {
        let commitment = income()
        let categoryID = UUID()
        let budget = Budget(
            name: "Gehalts-Budget",
            amount: 300,
            currency: .eur,
            periodPolicy: .salaryCycle(recurringIncomeID: commitment.id),
            categoryIDs: [categoryID]
        )
        let resolver = BudgetPeriodResolver()
        let calendar = makeCalendar()
        let now = date(2026, 8, 29)
        let payments = [
            salaryTransaction(on: date(2026, 7, 28)),
            salaryTransaction(on: date(2026, 8, 28))
        ]
        let resolved = try resolver.interval(
            for: budget,
            containing: now,
            calendar: calendar,
            recurringCommitments: [commitment],
            transactions: payments
        )

        // BudgetCalculator übernimmt die resolver-aufgelösten Intervalle
        // (identischer Pfad wie BudgetsModel.load).
        let progress = BudgetCalculator().progress(
            budgets: [budget],
            transactions: payments,
            categories: [],
            monthInterval: DateInterval(start: date(2026, 8, 1), end: date(2026, 9, 1)),
            calendar: calendar,
            intervals: [budget.id: resolved]
        ).first!

        #expect(progress.period == resolved)
        let recomputed = try BudgetPeriodResolver().interval(
            for: budget,
            containing: now,
            calendar: calendar,
            recurringCommitments: [commitment],
            transactions: payments
        )
        #expect(progress.period == recomputed)
    }
}

extension BudgetPeriodPolicy {
    var periodPolicySalaryIncomeID: UUID? {
        if case .salaryCycle(let id) = self { return id }
        return nil
    }
}