import Foundation
import Testing

@testable import FinanceTracker

@Suite("RecurringScheduleService")
struct RecurringScheduleServiceTests {

    private let service = RecurringScheduleService()

    private func calendar(timeZone: String = "Europe/Berlin") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func components(of date: Date, calendar: Calendar) -> (year: Int, month: Int, day: Int) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }

    private func commitment(cadence: RecurringCommitment.Cadence, nextExpected: Date? = nil) -> RecurringCommitment {
        RecurringCommitment(
            name: "Test",
            cadence: cadence,
            expectedAmount: 10,
            nextExpectedDate: nextExpected
        )
    }

    @Test("Weekly: exakt +7 Kalendertage")
    func weekly() {
        let calendar = calendar()
        let start = date(2026, 1, 5, calendar: calendar)
        let next = service.nextDate(after: start, cadence: .weekly, calendar: calendar)!
        #expect(components(of: next, calendar: calendar).day == 12)
    }

    @Test("Monthly: 15.01. → 15.02. → 15.03.")
    func monthlyNormal() {
        let calendar = calendar()
        var cursor = date(2026, 1, 15, calendar: calendar)
        for expected in [15, 15] {
            cursor = service.nextDate(after: cursor, cadence: .monthly, calendar: calendar)!
            #expect(components(of: cursor, calendar: calendar).day == expected)
        }
    }

    @Test("Monthly EOM: 31.01. → 28.02. → 31.03. → 30.04.")
    func monthlyEndOfMonth() {
        let calendar = calendar()
        var cursor = date(2026, 1, 31, calendar: calendar)

        cursor = service.nextDate(after: cursor, cadence: .monthly, calendar: calendar)!
        #expect(components(of: cursor, calendar: calendar).month == 2)
        #expect(components(of: cursor, calendar: calendar).day == 28)

        cursor = service.nextDate(after: cursor, cadence: .monthly, calendar: calendar)!
        #expect(components(of: cursor, calendar: calendar).month == 3)
        #expect(components(of: cursor, calendar: calendar).day == 31)

        cursor = service.nextDate(after: cursor, cadence: .monthly, calendar: calendar)!
        #expect(components(of: cursor, calendar: calendar).month == 4)
        #expect(components(of: cursor, calendar: calendar).day == 30)
    }

    @Test("Monthly EOM über Schaltjahr: 31.01.2024 → 29.02.2024")
    func monthlyLeapYearFebruary() {
        let calendar = calendar()
        var cursor = date(2024, 1, 31, calendar: calendar)
        cursor = service.nextDate(after: cursor, cadence: .monthly, calendar: calendar)!
        let c = components(of: cursor, calendar: calendar)
        #expect(c.month == 2 && c.day == 29)
    }

    @Test("Quarterly: 31.01. → 30.04. → 31.07. (EOM-Anchor)")
    func quarterly() {
        let calendar = calendar()
        var cursor = date(2026, 1, 31, calendar: calendar)

        cursor = service.nextDate(after: cursor, cadence: .quarterly, calendar: calendar)!
        var c = components(of: cursor, calendar: calendar)
        #expect(c.month == 4 && c.day == 30)

        cursor = service.nextDate(after: cursor, cadence: .quarterly, calendar: calendar)!
        c = components(of: cursor, calendar: calendar)
        #expect(c.month == 7 && c.day == 31)
    }

    @Test("Yearly: 29.02.2024 → 28.02.2025 (kein 29.02. im Folgejahr)")
    func yearlyFromLeapDay() {
        let calendar = calendar()
        let leapDay = date(2024, 2, 29, calendar: calendar)
        let next = service.nextDate(after: leapDay, cadence: .yearly, calendar: calendar)!
        let c = components(of: next, calendar: calendar)
        #expect(c.year == 2025 && c.month == 2 && c.day == 28)
    }

    @Test("Yearly: 31.12. → 31.12. des Folgejahres")
    func yearly() {
        let calendar = calendar()
        let start = date(2025, 12, 31, calendar: calendar)
        let next = service.nextDate(after: start, cadence: .yearly, calendar: calendar)!
        let c = components(of: next, calendar: calendar)
        #expect(c.year == 2026 && c.month == 12 && c.day == 31)
    }

    @Test("Occurrence-Generierung: mehrere wöchentliche Termine im Intervall")
    func multipleWeeklyOccurrences() {
        let calendar = calendar()
        let commitment = commitment(cadence: .weekly)
        let interval = DateInterval(
            start: date(2026, 1, 1, calendar: calendar),
            end: date(2026, 1, 31, calendar: calendar)
        )

        let occurrences = service.occurrences(for: commitment, in: interval, calendar: calendar)
        // Fällt vom Seed 01.01. wöchentlich: 01., 08., 15., 22., 29.
        let days = occurrences.map { components(of: $0, calendar: calendar).day }
        #expect(days == [1, 8, 15, 22, 29])
    }

    @Test("Occurrence am Intervallende gehört zur Folgeperiode")
    func occurrenceAtExclusiveEndIsExcluded() {
        let calendar = calendar()
        let septemberStart = date(2026, 9, 1, calendar: calendar)
        let octoberStart = date(2026, 10, 1, calendar: calendar)
        let commitment = commitment(cadence: .monthly, nextExpected: septemberStart)

        let occurrences = service.occurrences(
            for: commitment,
            in: DateInterval(start: septemberStart, end: octoberStart),
            calendar: calendar
        )

        #expect(occurrences == [septemberStart])
    }

    @Test("Kein Termin vor dem Intervall")
    func noOccurrenceBeforeInterval() {
        let calendar = calendar()
        let commitment = commitment(
            cadence: .monthly,
            nextExpected: date(2026, 3, 10, calendar: calendar)
        )
        let interval = DateInterval(
            start: date(2026, 1, 1, calendar: calendar),
            end: date(2026, 2, 28, calendar: calendar)
        )

        let occurrences = service.occurrences(for: commitment, in: interval, calendar: calendar)
        #expect(occurrences.isEmpty)
    }

    @Test("Yearly-Commitment ist in einem 30-Tage-Fenster nicht fällig")
    func yearlyNotDueInThirtyDays() {
        let calendar = calendar()
        let now = date(2026, 1, 15, calendar: calendar)
        let commitment = commitment(cadence: .yearly, nextExpected: date(2026, 12, 31, calendar: calendar))
        let interval = DateInterval(start: now, end: calendar.date(byAdding: .day, value: 30, to: now)!)

        #expect(!service.isDue(for: commitment, in: interval, calendar: calendar))
    }

    @Test("Monthly-Commitment mit Termin im Fenster ist fällig")
    func monthlyDueInWindow() {
        let calendar = calendar()
        let now = date(2026, 1, 15, calendar: calendar)
        let commitment = commitment(cadence: .monthly, nextExpected: date(2026, 1, 20, calendar: calendar))
        let interval = DateInterval(start: now, end: calendar.date(byAdding: .day, value: 30, to: now)!)

        #expect(service.isDue(for: commitment, in: interval, calendar: calendar))
    }

    @Test("Monthly-Equivalent-Divisoren: weekly/monthly/quarterly/yearly")
    func monthlyEquivalent() {
        #expect(service.monthlyEquivalentDivisor(cadence: .monthly) == 1)
        #expect(service.monthlyEquivalentDivisor(cadence: .quarterly) == 3)
        #expect(service.monthlyEquivalentDivisor(cadence: .yearly) == 12)
        // amount ÷ (12/52) = amount × 52/12 → wöchentlicher Betrag wird
        // korrekt auf den Monat umgerechnet.
        #expect(service.monthlyEquivalentDivisor(cadence: .weekly) == Decimal(string: "12.0")! / 52)
    }

    @Test("Matcher: nächster Termin nach letztem Match via Calendar")
    func matcherNextDateCalendarSafe() {
        let calendar = calendar()
        // Letzter Match: 31.01. → Monatsrhythmus → nächster Termin 28.02.2026
        // statt 31.01. + 30 Tage = 02.03.
        let commitment = RecurringCommitment(
            name: "Miete",
            merchantKey: "MIETE",
            cadence: .monthly,
            expectedAmount: 985,
            nextExpectedDate: nil
        )

        let txn = Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .demo,
            externalID: nil,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: Decimal(string: "-985.00")!, currency: .eur),
            bookedAt: date(2026, 1, 31, calendar: calendar),
            rawDescription: "Miete",
            rawMerchantName: "Miete"
        )

        let next = RecurringPaymentMatcher.nextExpectedDate(
            for: commitment,
            matching: [txn],
            calendar: calendar,
            now: date(2026, 2, 1, calendar: calendar)
        )!
        let c = components(of: next, calendar: calendar)
        #expect(c.month == 2 && c.day == 28)
    }
}
