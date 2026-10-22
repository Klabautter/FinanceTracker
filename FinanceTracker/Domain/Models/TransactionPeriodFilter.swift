import Foundation

/// Vordefinierte Zeiträume für den Transaktionsfilter. Die Intervalle sind
/// halboffen ([Start, Ende)) wie überall in der Auswertung.
enum TransactionPeriodFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case thisMonth
    case lastMonth
    case last30Days
    case last90Days
    case thisYear
    case lastYear
    /// Frei gewählter Bereich; die Grenzen liegen beim Aufrufer.
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: String(localized: "Gesamter Zeitraum")
        case .thisMonth: String(localized: "Dieser Monat")
        case .lastMonth: String(localized: "Letzter Monat")
        case .last30Days: String(localized: "Letzte 30 Tage")
        case .last90Days: String(localized: "Letzte 90 Tage")
        case .thisYear: String(localized: "Dieses Jahr")
        case .lastYear: String(localized: "Letztes Jahr")
        case .custom: String(localized: "Eigener Zeitraum …")
        }
    }

    /// Intervall für einen frei gewählten Bereich: beide Tage gehören
    /// vollständig dazu, vertauschte Grenzen werden geordnet.
    static func customInterval(from first: Date, through last: Date, calendar: Calendar) -> DateInterval? {
        let start = calendar.startOfDay(for: min(first, last))
        let lastDay = calendar.startOfDay(for: max(first, last))
        guard let end = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// `nil` = keine zeitliche Einschränkung.
    func interval(now: Date, calendar: Calendar) -> DateInterval? {
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return nil }

        func monthStart(offset: Int) -> Date? {
            guard let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) else { return nil }
            return calendar.date(byAdding: .month, value: offset, to: thisMonth)
        }
        func yearStart(offset: Int) -> Date? {
            guard let thisYear = calendar.date(from: calendar.dateComponents([.year], from: now)) else { return nil }
            return calendar.date(byAdding: .year, value: offset, to: thisYear)
        }
        func interval(_ start: Date?, _ end: Date?) -> DateInterval? {
            guard let start, let end, start < end else { return nil }
            return DateInterval(start: start, end: end)
        }

        switch self {
        case .all, .custom:
            // `.custom` hat keine festen Grenzen: siehe `customInterval`.
            return nil
        case .thisMonth:
            return interval(monthStart(offset: 0), monthStart(offset: 1))
        case .lastMonth:
            return interval(monthStart(offset: -1), monthStart(offset: 0))
        case .last30Days:
            return interval(calendar.date(byAdding: .day, value: -29, to: startOfToday), startOfTomorrow)
        case .last90Days:
            return interval(calendar.date(byAdding: .day, value: -89, to: startOfToday), startOfTomorrow)
        case .thisYear:
            return interval(yearStart(offset: 0), yearStart(offset: 1))
        case .lastYear:
            return interval(yearStart(offset: -1), yearStart(offset: 0))
        }
    }
}
