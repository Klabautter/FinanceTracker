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
}
