import Foundation
import Testing

@testable import FinanceTracker

/// Monatswechsel (Roadmap 3.8): Die Übersicht bereitet den Vormonat im
/// Hintergrund vor. Ein vorbereiteter Monat muss genau wie ein frisch
/// geladener aussehen und darf nach einer Änderung nie veraltet erscheinen.
/// Große Zeiträume werden parallel in Teilen gelesen, ohne Zeilen zu
/// verlieren oder doppelt zu liefern.
@MainActor
@Suite("Dashboard-Monatswechsel")
struct DashboardMonthPrefetchTests {
    private static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// Eine Ausgabe je Tag über die letzten acht Monate.
    private static func seed(_ dependencies: AppDependencies, now: Date, calendar: Calendar) async throws -> Account {
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let rows = (1...240).map { day in
            Transaction(
                accountID: account.id, source: .manual, externalID: "d\(day)",
                status: .booked, kind: .purchase,
                amount: Money(amount: -Decimal(day % 40 + 1), currency: .eur),
                bookedAt: calendar.date(byAdding: .day, value: -day, to: now),
                rawDescription: "Laden \(day % 9)"
            )
        }
        try await dependencies.transactionRepository.upsert(rows)
        return account
    }

    @Test("Der vorbereitete Vormonat gleicht einem frisch geladenen")
    func prefetchedMonthMatchesFreshLoad() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let calendar = Self.calendar()
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 12)))
        _ = try await Self.seed(dependencies, now: now, calendar: calendar)

        let prefetching = DashboardModel(dependencies: dependencies, calendar: calendar, now: { now })
        await prefetching.load()
        await prefetching.showPreviousMonth()

        // Ohne vorheriges Laden gibt es nichts Vorbereitetes.
        let fresh = DashboardModel(dependencies: dependencies, calendar: calendar, now: { now })
        await fresh.showPreviousMonth()

        #expect(prefetching.snapshot != nil)
        #expect(prefetching.snapshot == fresh.snapshot)
        #expect(prefetching.previousSnapshot == fresh.previousSnapshot)
        #expect(prefetching.monthlyPoints == fresh.monthlyPoints)
        #expect(prefetching.dashboardInterval == fresh.dashboardInterval)
    }

    @Test("Nach einer Änderung zeigt der Monatswechsel den neuen Stand")
    func changeInvalidatesPrefetchedMonth() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let calendar = Self.calendar()
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 12)))
        let account = try await Self.seed(dependencies, now: now, calendar: calendar)

        let model = DashboardModel(dependencies: dependencies, calendar: calendar, now: { now })
        await model.load()
        let julyBooking = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 9)))
        try await dependencies.transactionRepository.upsert([Transaction(
            accountID: account.id, source: .manual, externalID: "neu",
            status: .booked, kind: .purchase,
            amount: Money(amount: -500, currency: .eur),
            bookedAt: julyBooking, rawDescription: "Nachgetragen"
        )])
        dependencies.changeTracker.markChanged()
        await model.showPreviousMonth()

        let fresh = DashboardModel(dependencies: dependencies, calendar: calendar, now: { now })
        await fresh.showPreviousMonth()
        #expect(model.snapshot == fresh.snapshot)
        #expect(model.snapshot?.transactionCount == fresh.snapshot?.transactionCount)
    }

    @Test("Große Zeiträume werden parallel ohne Verlust gelesen")
    func largeIntervalReadsEveryRowOnce() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let calendar = Self.calendar()
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let count = LocalTransactionRepository.parallelIntervalThreshold + 500
        let step = end.timeIntervalSince(start) / Double(count)
        let inside = (0..<count).map { index in
            Transaction(
                accountID: account.id, source: .manual, externalID: "in\(index)",
                status: .booked, kind: .purchase,
                amount: Money(amount: -1, currency: .eur),
                bookedAt: start.addingTimeInterval(step * Double(index)),
                rawDescription: "Zeile \(index)"
            )
        }
        // Grenzfälle: genau am Ende (gehört nicht dazu) und kurz davor.
        let outside = Transaction(
            accountID: account.id, source: .manual, externalID: "out",
            status: .booked, kind: .purchase,
            amount: Money(amount: -1, currency: .eur), bookedAt: end, rawDescription: "Danach"
        )
        try await dependencies.transactionRepository.upsert(inside + [outside])

        var query = TransactionQuery()
        query.dateInterval = DateInterval(start: start, end: end)
        let loaded = try await dependencies.transactionRepository.transactions(matching: query)
        #expect(loaded.count == count)
        #expect(Set(loaded.map(\.id)) == Set(inside.map(\.id)))
    }
}
