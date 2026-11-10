import Foundation
import Testing

@testable import FinanceTracker

/// „% vs. Vorperiode" vergleicht Gleiches mit Gleichem: Der laufende
/// Zeitraum ist erst bis heute gefüllt, die Vorperiode zählt deshalb nur
/// bis zum entsprechenden Tag und beginnt am selben Kalendertag.
@MainActor
@Suite("AnalyticsPreviousPeriod")
struct AnalyticsPreviousPeriodTests {
    /// Jeden Tag genau 10 € Ausgaben, 800 Tage zurück bis einschließlich heute.
    private func makeModelWithConstantSpending() async throws -> AnalyticsModel {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let transactions = (0..<800).map { offset -> Transaction in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            return Transaction(
                accountID: account.id,
                source: .manual,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -10, currency: .eur),
                bookedAt: day.addingTimeInterval(60),
                rawDescription: "Markt",
                rawMerchantName: "Markt",
                merchantDisplayName: "Markt"
            )
        }
        try await dependencies.transactionRepository.upsert(transactions)
        return AnalyticsModel(dependencies: dependencies)
    }

    @Test("Dieses Jahr: gleichbleibende Ausgaben ergeben keinen Trend gegen das ganze Vorjahr")
    func thisYearComparesSameSpanOfLastYear() async throws {
        let model = try await makeModelWithConstantSpending()
        model.range = .thisYear
        await model.load()

        let trend = try #require(model.spendingTrendPercent)
        #expect(abs(trend) < 0.02)
    }

    @Test("Letzte 3 Monate: gleichbleibende Ausgaben ergeben keinen Trend")
    func lastThreeMonthsComparesSameSpan() async throws {
        let model = try await makeModelWithConstantSpending()
        model.range = .last3Months
        await model.load()

        let trend = try #require(model.spendingTrendPercent)
        // Monate sind verschieden lang: wenige Tage Unterschied sind erlaubt.
        #expect(abs(trend) < 0.06)
    }

    @Test("Kein Trend, wenn ein Konto mit Ausgaben erst spät in der Vorperiode Daten hat")
    func noTrendWhenAnAccountJoinedLate() {
        let previous = DateInterval(start: date(2024, 11, 10), end: date(2025, 11, 10))
        let broker = UUID()
        let bank = UUID()
        func expense(_ account: UUID, _ day: Date) -> Transaction {
            Transaction(accountID: account, source: .manual, kind: .purchase,
                        amount: Money(amount: -10, currency: .eur), bookedAt: day, rawMerchantName: "Test")
        }
        let current = [expense(broker, date(2026, 3, 1)), expense(bank, date(2026, 3, 1))]
        // Broker hat die ganze Vorperiode Daten, die Bank erst ab Oktober 2025.
        let lateBank = [expense(broker, date(2024, 12, 1)), expense(bank, date(2025, 10, 21))]
        #expect(!AnalyticsModel.previousPeriodCovered(current: current, previous: lateBank, previousInterval: previous))

        let bothEarly = [expense(broker, date(2024, 12, 1)), expense(bank, date(2025, 1, 5))]
        #expect(AnalyticsModel.previousPeriodCovered(current: current, previous: bothEarly, previousInterval: previous))
    }

    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test("Laufender Zeitraum: Vorperiode beginnt am selben Kalendertag und endet am entsprechenden Tag")
    func runningPeriodIsComparedToDate() {
        let previous = AnalyticsModel.previousInterval(
            current: DateInterval(start: date(2026, 9, 1), end: date(2026, 12, 1)),
            now: date(2026, 11, 9, hour: 12),
            calendar: berlin
        )
        #expect(previous == DateInterval(start: date(2026, 6, 1), end: date(2026, 8, 10)))
    }

    @Test("Dieses Jahr: Vorjahr nur bis zum heutigen Kalendertag")
    func runningYearIsComparedToDate() {
        let previous = AnalyticsModel.previousInterval(
            current: DateInterval(start: date(2026, 1, 1), end: date(2027, 1, 1)),
            now: date(2026, 11, 9, hour: 12),
            calendar: berlin
        )
        #expect(previous == DateInterval(start: date(2025, 1, 1), end: date(2025, 11, 10)))
    }

    @Test("Abgeschlossener Zeitraum: ganze Vorperiode in Kalendermonaten")
    func completedPeriodUsesWholePreviousPeriod() {
        let previous = AnalyticsModel.previousInterval(
            current: DateInterval(start: date(2026, 9, 1), end: date(2026, 12, 1)),
            now: date(2026, 12, 3),
            calendar: berlin
        )
        #expect(previous == DateInterval(start: date(2026, 6, 1), end: date(2026, 9, 1)))
    }
}
