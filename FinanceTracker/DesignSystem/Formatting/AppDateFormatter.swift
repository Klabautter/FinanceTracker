import Foundation

/// Locale-aware Datum-Darstellung für die UI (WP2).
///
/// Date.FormatStyle statt statischer DateFormatter-Instanzen: value-typ,
/// thread-safe, folgt der injizierten Locale. Provider-/API-Parser nutzen
/// weiterhin ihre eigenen Formatter; hier liegt reine Präsentation.
enum AppDateFormatter {
    static func day(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(.dateTime.day().month().year().locale(locale))
    }

    static func weekdayDay(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month().locale(locale))
    }

    static func monthYear(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(.dateTime.month(.wide).year().locale(locale))
    }

    /// Alter eines Zeitpunkts in Minuten, Stunden oder Tagen („vor 8 Tagen“),
    /// ab 60 Tagen als Datum. Der relative Systemstil rechnet in
    /// Kalenderwochen und -monaten und macht aus acht Tagen „vor 2 Wochen“.
    static func relativeAge(_ date: Date, relativeTo now: Date = Date(), locale: Locale = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return String(localized: "gerade eben") }
        var components = DateComponents()
        switch seconds {
        case ..<3_600: components.minute = -Int(seconds / 60)
        case ..<86_400: components.hour = -Int(seconds / 3_600)
        case ..<(60 * 86_400): components.day = -Int(seconds / 86_400)
        default: return day(date, locale: locale)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(from: components)
    }
}
