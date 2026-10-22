import Foundation

/// Kumulierter Ausgabenverlauf eines Monats im Vergleich zum Vormonat
/// („Ausgabentempo"). Basis sind die täglichen Bruttoausgaben aus dem
/// `AnalyticsSnapshot`, damit Übersicht und Analyse dieselbe effektive
/// Transaktionssemantik verwenden.
struct SpendingPacePoint: Identifiable, Hashable, Sendable {
    /// Tag im Monat, 1-basiert.
    let day: Int
    let cumulative: Decimal

    var id: Int { day }
}

struct SpendingPace: Hashable, Sendable {
    /// Laufender Monat bis einschließlich heute.
    let current: [SpendingPacePoint]
    /// Vollständiger Vormonat.
    let previous: [SpendingPacePoint]
    let daysInCurrentMonth: Int

    var currentTotal: Decimal { current.last?.cumulative ?? 0 }

    /// Vormonat am selben Tag (bei kürzerem Vormonat dessen letzter Tag).
    var previousAtSameDay: Decimal? {
        guard let today = current.last?.day, !previous.isEmpty else { return nil }
        return previous.last { $0.day <= today }?.cumulative ?? 0
    }

    /// Positiv = mehr ausgegeben als im Vormonat zum selben Zeitpunkt.
    var deltaToPrevious: Decimal? {
        previousAtSameDay.map { currentTotal - $0 }
    }

    static func make(
        currentDaily: [DailyTotal],
        currentInterval: DateInterval,
        previousDaily: [DailyTotal],
        previousInterval: DateInterval?,
        now: Date,
        calendar: Calendar = .current
    ) -> SpendingPace {
        let daysInCurrent = calendar.range(of: .day, in: .month, for: currentInterval.start)?.count ?? 30
        let todayIndex: Int
        if now < currentInterval.start {
            todayIndex = 0
        } else if now >= currentInterval.end {
            todayIndex = daysInCurrent
        } else {
            todayIndex = min(daysInCurrent, calendar.component(.day, from: now))
        }
        let current = cumulative(daily: currentDaily, interval: currentInterval, upToDay: todayIndex, calendar: calendar)

        var previous: [SpendingPacePoint] = []
        if let previousInterval {
            let daysInPrevious = calendar.range(of: .day, in: .month, for: previousInterval.start)?.count ?? 30
            previous = cumulative(daily: previousDaily, interval: previousInterval, upToDay: daysInPrevious, calendar: calendar)
        }
        return SpendingPace(current: current, previous: previous, daysInCurrentMonth: daysInCurrent)
    }

    private static func cumulative(
        daily: [DailyTotal],
        interval: DateInterval,
        upToDay lastDay: Int,
        calendar: Calendar
    ) -> [SpendingPacePoint] {
        guard lastDay > 0 else { return [] }
        var byDay: [Int: Decimal] = [:]
        for entry in daily where interval.containsHalfOpen(entry.day) {
            byDay[calendar.component(.day, from: entry.day), default: 0] += entry.amount
        }
        var running = Decimal(0)
        return (1...lastDay).map { day in
            running += byDay[day] ?? 0
            return SpendingPacePoint(day: day, cumulative: running)
        }
    }
}
