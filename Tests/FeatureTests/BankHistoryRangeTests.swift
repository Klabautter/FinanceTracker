import Foundation
import Testing

@testable import FinanceTracker

@Suite("BankHistoryRange")
struct BankHistoryRangeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("Zeiträume ergeben das Startdatum für den ersten Abruf")
    func startDates() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 14))!
        #expect(BankConnectModel.HistoryRange.bankDefault.startDate(now: now, calendar: calendar) == nil)
        #expect(BankConnectModel.HistoryRange.oneYear.startDate(now: now, calendar: calendar) == day(2025, 10, 20))
        #expect(BankConnectModel.HistoryRange.twoYears.startDate(now: now, calendar: calendar) == day(2024, 10, 20))
    }

    @Test("Hinweis sagt ehrlich, wenn die Bank weniger liefert als angefragt")
    func notices() {
        let delivered = day(2026, 7, 28)
        #expect(BankConnectModel.historyNotice(requestedStart: nil, earliestDelivered: delivered)
            == "Umsätze ab \(AppDateFormatter.day(delivered)) geladen.")
        #expect(BankConnectModel.historyNotice(requestedStart: day(2026, 7, 10), earliestDelivered: delivered)
            == "Umsätze ab \(AppDateFormatter.day(delivered)) geladen.")

        let requested = day(2025, 10, 20)
        let truncated = BankConnectModel.historyNotice(requestedStart: requested, earliestDelivered: delivered)
        #expect(truncated?.hasPrefix("Angefragt ab \(AppDateFormatter.day(requested)), die Bank hat Umsätze ab \(AppDateFormatter.day(delivered)) geliefert.") == true)

        #expect(BankConnectModel.historyNotice(requestedStart: requested, earliestDelivered: nil)
            == "Die Bank hat für diesen Zeitraum keine Umsätze geliefert.")
        #expect(BankConnectModel.historyNotice(requestedStart: nil, earliestDelivered: nil) == nil)
    }
}
