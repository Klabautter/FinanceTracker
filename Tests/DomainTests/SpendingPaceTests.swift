import Foundation
import Testing

@testable import FinanceTracker

@Suite("SpendingPace")
struct SpendingPaceTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func month(_ year: Int, _ month: Int) -> DateInterval {
        calendar.dateInterval(of: .month, for: day(year, month, 1))!
    }

    @Test("Kumuliert laufenden Monat bis heute und vergleicht mit Vormonat am selben Tag")
    func cumulativeComparison() {
        let pace = SpendingPace.make(
            currentDaily: [
                DailyTotal(day: day(2026, 9, 1), amount: 100),
                DailyTotal(day: day(2026, 9, 3), amount: 50),
                DailyTotal(day: day(2026, 9, 20), amount: 999) // nach "heute"
            ],
            currentInterval: month(2026, 9),
            previousDaily: [
                DailyTotal(day: day(2026, 8, 2), amount: 30),
                DailyTotal(day: day(2026, 8, 5), amount: 70),
                DailyTotal(day: day(2026, 8, 31), amount: 10)
            ],
            previousInterval: month(2026, 8),
            now: day(2026, 9, 4).addingTimeInterval(3_600),
            calendar: calendar
        )

        #expect(pace.current.count == 4)
        #expect(pace.current.map(\.cumulative) == [100, 100, 150, 150])
        #expect(pace.currentTotal == 150)
        #expect(pace.previous.count == 31)
        #expect(pace.previous.last?.cumulative == 110)
        // Vormonat bis zum 4.: 30
        #expect(pace.previousAtSameDay == 30)
        #expect(pace.deltaToPrevious == 120)
        #expect(pace.daysInCurrentMonth == 30)
    }

    @Test("Kürzerer Vormonat nutzt seinen letzten Tag als Vergleich")
    func shorterPreviousMonth() {
        let pace = SpendingPace.make(
            currentDaily: [DailyTotal(day: day(2026, 3, 30), amount: 20)],
            currentInterval: month(2026, 3),
            previousDaily: [DailyTotal(day: day(2026, 2, 28), amount: 80)],
            previousInterval: month(2026, 2),
            now: day(2026, 3, 30).addingTimeInterval(3_600),
            calendar: calendar
        )
        #expect(pace.previousAtSameDay == 80)
        #expect(pace.deltaToPrevious == -60)
    }

    @Test("Ohne Vormonat gibt es keinen Vergleich")
    func missingPreviousMonth() {
        let pace = SpendingPace.make(
            currentDaily: [],
            currentInterval: month(2026, 9),
            previousDaily: [],
            previousInterval: nil,
            now: day(2026, 9, 2),
            calendar: calendar
        )
        #expect(pace.previous.isEmpty)
        #expect(pace.deltaToPrevious == nil)
        #expect(pace.currentTotal == 0)
    }
}
