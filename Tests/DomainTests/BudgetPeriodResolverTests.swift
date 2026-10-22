import Foundation
import Testing

@testable import FinanceTracker

@Suite("BudgetPeriodResolver")
struct BudgetPeriodResolverTests {

    private let resolver = BudgetPeriodResolver()

    private func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func budget(startDay: Int) -> Budget {
        Budget(name: "Test", amount: 100, periodPolicy: .calendarMonth(startDay: startDay))
    }

    private func day(of date: Date) -> (month: Int, day: Int) {
        let c = calendar()
        let components = c.dateComponents([.month, .day], from: date)
        return (components.month!, components.day!)
    }

    // MARK: - calendarMonth(startDay: 1)

    @Test("Start day 1: normaler Kalendermonat")
    func startDay1() throws {
        let interval = try resolver.interval(
            for: budget(startDay: 1),
            containing: date(2026, 3, 15),
            calendar: calendar()
        )
        #expect(day(of: interval.start) == (3, 1))
        #expect(day(of: interval.end) == (4, 1))
    }

    @Test("Start day 1 über Jahreswechsel: Dezember → Januar")
    func decemberToJanuary() throws {
        let interval = try resolver.interval(
            for: budget(startDay: 1),
            containing: date(2026, 12, 20),
            calendar: calendar()
        )
        #expect(day(of: interval.start) == (12, 1))
        #expect(day(of: interval.end) == (1, 1))
    }

    // MARK: - calendarMonth(startDay: 15)

    @Test("Start day 15: 10.02. liegt in der Periode 15.01.–15.02.")
    func startDay15BeforeAnchor() throws {
        let interval = try resolver.interval(
            for: budget(startDay: 15),
            containing: date(2026, 2, 10),
            calendar: calendar()
        )
        #expect(day(of: interval.start) == (1, 15))
        #expect(day(of: interval.end) == (2, 15))
    }

    @Test("Start day 15: 20.02. liegt in der Periode 15.02.–15.03.")
    func startDay15AfterAnchor() throws {
        let interval = try resolver.interval(
            for: budget(startDay: 15),
            containing: date(2026, 2, 20),
            calendar: calendar()
        )
        #expect(day(of: interval.start) == (2, 15))
        #expect(day(of: interval.end) == (3, 15))
    }

    @Test("Start day 31 im Februar: geklemmt auf Monatsende (Schaltjahr)")
    func startDay31FebruaryLeapYear() throws {
        let interval = try resolver.interval(
            for: budget(startDay: 31),
            containing: date(2024, 2, 15),
            calendar: calendar()
        )
        // Periode: 31.01.2024: 29.02.2024 (geklämmt)
        #expect(day(of: interval.start) == (1, 31))
        #expect(day(of: interval.end) == (2, 29))
    }

    @Test("Start day 31 im Februar (kein Schaltjahr): geklemmt auf 28.")
    func startDay31February() throws {
        let interval = try resolver.interval(
            for: budget(startDay: 31),
            containing: date(2026, 2, 15),
            calendar: calendar()
        )
        #expect(day(of: interval.start) == (1, 31))
        #expect(day(of: interval.end) == (2, 28))
    }

    // MARK: - previousInterval

    @Test("Previous interval: Tag vor dem Start des aktuellen Intervalls")
    func previousInterval() throws {
        let budget = budget(startDay: 1)
        let current = try resolver.interval(
            for: budget, containing: date(2026, 3, 15), calendar: calendar()
        )
        let previous = try resolver.previousInterval(
            for: budget, containing: date(2026, 3, 15), calendar: calendar()
        )
        #expect(previous.end == current.start)
        #expect(day(of: previous.start) == (2, 1))
    }

    @Test("Previous interval mit startDay 15: 15.12.–15.01. vor 15.01.–15.02.")
    func previousIntervalCustomStart() throws {
        // 20.01. liegt in [15.01., 15.02.) → previous = [15.12.2025, 15.01.2026)
        let previous = try resolver.previousInterval(
            for: budget(startDay: 15),
            containing: date(2026, 1, 20),
            calendar: calendar()
        )
        #expect(day(of: previous.start) == (12, 15))
        #expect(day(of: previous.end) == (1, 15))
    }

    // MARK: - progress

    @Test("Elapsed/total days: Mitte des Monats")
    func progressDays() {
        let interval = DateInterval(
            start: date(2026, 3, 1),
            end: date(2026, 4, 1)
        )
        let progress = resolver.progress(in: interval, now: date(2026, 3, 15), calendar: calendar())
        #expect(progress.totalDays == 31)
        #expect(progress.elapsedDays == 14) // Differenztage 1.3. → 15.3.
    }

    @Test("Elapsed klemmt am Intervallende (zukünftiges now)")
    func progressFutureNow() {
        let interval = DateInterval(
            start: date(2026, 3, 1),
            end: date(2026, 4, 1)
        )
        let progress = resolver.progress(in: interval, now: date(2026, 5, 1), calendar: calendar())
        #expect(progress.totalDays == 31)
        #expect(progress.elapsedDays == 31)
    }

    // MARK: - salaryCycle

    @Test("Salary cycle: Intervall zwischen den letzten beiden Gehältern")
    func salaryCycle() throws {
        let incomeID = UUID()
        let incomeCommitment = RecurringCommitment(
            id: incomeID,
            name: "Gehalt",
            merchantKey: "GEHALT ACME",
            direction: .income,
            cadence: .monthly,
            amountPolicy: .fixed,
            expectedAmount: 2850,
            currency: .eur,
            status: .active
        )
        let salaryBudget = Budget(
            name: "Gehalt-zu-Gehalt",
            amount: 1000,
            periodPolicy: .salaryCycle(recurringIncomeID: incomeID)
        )

        var txns: [Transaction] = []
        for index in 0..<3 {
            let booked = calendar().date(
                byAdding: .month, value: -index,
                to: date(2026, 3, 26)
            )!
            txns.append(Transaction(
                id: UUID(),
                accountID: UUID(),
                source: .demo,
                externalID: UUID().uuidString,
                status: .booked,
                kind: .income,
                amount: Money(amount: 2850, currency: .eur),
                bookedAt: booked,
                rawDescription: "GEHALT ACME",
                rawMerchantName: "GEHALT ACME",
                merchantDisplayName: "GEHALT ACME"
            ))
        }

        let interval = try resolver.interval(
            for: salaryBudget,
            containing: date(2026, 3, 15),
            calendar: calendar(),
            recurringCommitments: [incomeCommitment],
            transactions: txns
        )
        // Letzte Zahlung: 26.02. (Index 1, gekauft 3.-26.). Vorletzte: 28.01.
        // Enthaltenes Intervall: [28.01., 26.02.)?: 15.03. liegt danach,
        // also das letzte Paar: [26.02., 26.03.).
        #expect(day(of: interval.start) == (2, 26))
        #expect(day(of: interval.end) == (3, 26))
    }

    @Test("Fehlendes Income-Commitment → kontrollierter Fehler")
    func missingSalaryCommitment() {
        let missingIncomeID = UUID()
        let salaryBudget = Budget(
            name: "Gehalt-zu-Gehalt",
            amount: 1000,
            periodPolicy: .salaryCycle(recurringIncomeID: missingIncomeID)
        )

        #expect(throws: BudgetPeriodResolverError.missingSalaryCommitment(incomeID: missingIncomeID)) {
            try resolver.interval(
                for: salaryBudget,
                containing: date(2026, 3, 15),
                calendar: calendar(),
                recurringCommitments: [],
                transactions: []
            )
        }
    }

    /// WP6 (§45): Eine einzige Zahlung genügt
    /// start = reale Zahlung, end = Schedule-Prognose. Der alte
    /// „insufficient history"-Fall gilt nur noch ohne Zahlung.
    @Test("Eine Zahlung genügt → aktiver Zyklus mit Schedule-Ende (§45)")
    func singlePaymentYieldsActiveCycle() {
        let incomeID = UUID()
        let incomeCommitment = RecurringCommitment(
            id: incomeID,
            name: "Gehalt",
            merchantKey: "GEHALT ACME",
            direction: .income,
            cadence: .monthly,
            amountPolicy: .fixed,
            expectedAmount: 2850,
            currency: .eur,
            status: .active
        )
        let salaryBudget = Budget(
            name: "Gehalt-zu-Gehalt",
            amount: 1000,
            periodPolicy: .salaryCycle(recurringIncomeID: incomeID)
        )
        let onlyOne = Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .demo,
            externalID: UUID().uuidString,
            status: .booked,
            kind: .income,
            amount: Money(amount: 2850, currency: .eur),
            bookedAt: date(2026, 3, 1),
            rawDescription: "GEHALT ACME",
            rawMerchantName: "GEHALT ACME",
            merchantDisplayName: "GEHALT ACME"
        )

        do {
            let interval = try resolver.interval(
                for: salaryBudget,
                containing: date(2026, 3, 15),
                calendar: calendar(),
                recurringCommitments: [incomeCommitment],
                transactions: [onlyOne]
            )
            #expect(interval.start == date(2026, 3, 1))
            #expect(interval.end == date(2026, 4, 1))
            #expect(interval.contains(date(2026, 3, 15)))
        } catch {
            Issue.record("Erwartete aktiven Zyklus, erhalten: \(error)")
        }
    }
}
