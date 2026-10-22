import Foundation

/// Reine Darstellungslogik der Fokus-Übersicht (keine Logik in Views). Alles hier ist deterministisch und ohne SwiftUI testbar.
enum DashboardInsights {

    // MARK: - Verbrauchs-Tempo

    /// Das Leitelement der Fokus-Übersicht: Wie viel des Monatsbudgets ist
    /// verbraucht, im Verhältnis dazu, wie viel des Monats vorbei ist.
    ///
    /// Der Vergleich beantwortet die eigentliche Frage („bin ich zu schnell?")
    /// deutlich direkter als ein absoluter Betrag.
    struct Pace: Equatable, Sendable {
        /// Anteil des Rahmens, der verbraucht ist (0…1, gekappt).
        let spentFraction: Double
        /// Anteil des Zeitraums, der verstrichen ist (0…1, gekappt).
        let elapsedFraction: Double

        /// Toleranz, damit minimale Abweichungen nicht als Warnung erscheinen.
        private static let tolerance = 0.03

        var isOverPace: Bool { spentFraction > elapsedFraction + Self.tolerance }
        var isUnderPace: Bool { spentFraction < elapsedFraction - Self.tolerance }

        var spentPercent: Int { Int((spentFraction * 100).rounded()) }
        var elapsedPercent: Int { Int((elapsedFraction * 100).rounded()) }

        var summary: String {
            if isOverPace { return String(localized: "Schneller als der Monat") }
            if isUnderPace { return String(localized: "Langsamer als der Monat") }
            return String(localized: "Im Takt des Monats")
        }
    }

    /// Der Rahmen ergibt sich primär aus dem Forecast (verbraucht + noch
    /// verfügbar). Ohne belastbaren Forecast dienen die Budget-Limits als
    /// Bezug. Fehlt beides, gibt es kein sinnvolles Tempo, dann `nil`
    /// (kein erfundener Bezugswert).
    static func pace(
        spent: Decimal,
        available: Decimal?,
        budgetLimit: Decimal?,
        interval: DateInterval?,
        now: Date
    ) -> Pace? {
        guard let interval else { return nil }

        let envelope: Decimal
        if let available {
            envelope = spent + max(0, available)
        } else if let budgetLimit, budgetLimit > 0 {
            envelope = budgetLimit
        } else {
            return nil
        }
        guard envelope > 0 else { return nil }

        let total = interval.end.timeIntervalSince(interval.start)
        guard total > 0 else { return nil }
        let elapsed = now.timeIntervalSince(interval.start)

        return Pace(
            spentFraction: clamped(double(spent) / double(envelope)),
            elapsedFraction: clamped(elapsed / total)
        )
    }

    // MARK: - Ausgaben-Spektrum

    /// Ein Segment des durchgehenden Ausgabenbalkens.
    struct SpectrumSegment: Identifiable, Equatable, Sendable {
        let id: String
        let categoryID: UUID?
        let name: String
        let amount: Decimal
        let fraction: Double
        var percent: Int { Int((fraction * 100).rounded()) }
        /// Sammelsegment „Weitere" ist nicht anklickbar (keine einzelne
        /// Kategorie dahinter).
        let isAggregate: Bool
    }

    /// Die größten Bereiche als Segmente; der Rest wird zu genau einem
    /// Sammelsegment gebündelt, damit der Balken immer 100 % ergibt.
    static func spectrum(
        from items: [CategoryTotal],
        maxSegments: Int = 6
    ) -> [SpectrumSegment] {
        let positive = items.filter { $0.amount > 0 }
        let total = positive.reduce(into: Decimal(0)) { $0 += $1.amount }
        guard total > 0 else { return [] }

        let leading = positive.prefix(maxSegments)
        var segments = leading.map { item in
            SpectrumSegment(
                id: item.id,
                categoryID: item.categoryID,
                name: item.name,
                amount: item.amount,
                fraction: clamped(double(item.amount) / double(total)),
                isAggregate: false
            )
        }

        let remainder = positive.dropFirst(maxSegments)
        if !remainder.isEmpty {
            let amount = remainder.reduce(into: Decimal(0)) { $0 += $1.amount }
            segments.append(SpectrumSegment(
                id: "aggregate:weitere",
                categoryID: nil,
                name: String(localized: "Weitere"),
                amount: amount,
                fraction: clamped(double(amount) / double(total)),
                isAggregate: true
            ))
        }

        return segments
    }

    // MARK: - Zeitraum

    /// „Tag 18 von 30" (ohne Betrag), deshalb auch bei Privacy sichtbar.
    static func dayProgressText(interval: DateInterval?, now: Date, calendar: Calendar = .current) -> String? {
        guard let interval else { return nil }
        let startDay = calendar.startOfDay(for: interval.start)
        guard let totalDays = calendar.dateComponents([.day], from: startDay, to: interval.end).day,
              totalDays > 0,
              let elapsedDays = calendar.dateComponents([.day], from: startDay, to: calendar.startOfDay(for: now)).day
        else { return nil }
        let current = min(max(elapsedDays + 1, 1), totalDays)
        return String(localized: "Tag \(current) von \(totalDays)")
    }

    // MARK: - Sprache

    /// „1 Buchung", nicht „1 Buchungen".
    static func bookings(_ count: Int) -> String {
        count == 1 ? String(localized: "\(count) Buchung") : String(localized: "\(count) Buchungen")
    }

    /// Zählangabe mit passender Verbform: „1 Buchung wurde", „2 Buchungen wurden".
    static func bookingsWere(_ count: Int) -> String {
        count == 1 ? String(localized: "\(count) Buchung wurde") : String(localized: "\(count) Buchungen wurden")
    }

    // MARK: - Hilfen

    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
