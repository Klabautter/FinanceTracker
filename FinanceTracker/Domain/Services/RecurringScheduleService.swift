import Foundation

/// Calendar-sicheres Scheduling für wiederkehrende Zahlungen (WP3).
///
/// Source of Truth für Termine: Wochen/Monate/Quartale/Jahre als
/// Kalender-Komponenten statt approximierter Tagesanzahl (7/30/91/365).
///
/// End-of-Month-Policy: Ein Commitment am letzten gültigen Tag des Monats
/// bleibt am letzten gültigen Tag der Folgemonate (31.01. → 28./29.02. →
/// 31.03. → 30.04.). `Calendar.date(byAdding:)` clamped Day-Overflow genau
/// so: der Service modelliert das als bewusste Policy und stabilisiert
/// den Tag zusätzlich über `nextDate(after:)`.
struct RecurringScheduleService: Sendable {
    /// Nächster Termin nach `date` (exklusiv) für die gegebene Cadence.
    ///
    /// Gibt `nil` zurück, wenn der Kalender kein gültiges Datum liefern kann.
    func nextDate(
        after date: Date,
        cadence: RecurringCommitment.Cadence,
        calendar: Calendar
    ) -> Date? {
        switch cadence {
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .monthly:
            return advanced(byMonths: 1, from: date, calendar: calendar)
        case .quarterly:
            return advanced(byMonths: 3, from: date, calendar: calendar)
        case .yearly:
            return advanced(byMonths: 12, from: date, calendar: calendar)
        }
    }

    /// Alle Termine eines Commitments innerhalb des Intervalls.
    ///
    /// Basis: gespeicherte Planung (`nextExpectedDate`) bzw. `interval.start`
    /// als Seed; Termine werden kalendarisch fortgeschrieben, bis das
    /// Intervall verlassen wird. Sicherheit: max. 1.000 Schritte gegen
    /// endlose Schleifen bei kaputten Eingaben.
    func occurrences(
        for commitment: RecurringCommitment,
        in interval: DateInterval,
        calendar: Calendar
    ) -> [Date] {
        var result: [Date] = []
        var cursor = seedDate(for: commitment, in: interval, calendar: calendar)
        var steps = 0

        while let candidate = cursor, steps < 1_000 {
            steps += 1
            // DateInterval wird im gesamten Finanzmodell als halb-offen
            // [start, end) verwendet. Ein Termin exakt am Periodenende
            // gehört bereits zur Folgeperiode (z. B. 1. Oktober nicht mehr
            // zum September).
            if candidate >= interval.end {
                break
            }
            if candidate >= interval.start {
                result.append(candidate)
            }
            cursor = nextDate(after: candidate, cadence: commitment.cadence, calendar: calendar)
        }

        return result
    }

    /// Schedule-Seed aus der letzten realen Zahlung für `period`: Liegt die
    /// Zahlung selbst im Zeitraum, IST sie dessen Termin (sonst würde der
    /// Plan auf den Folgetermin springen und der bereits bezahlte Termin
    /// im Zeitraum als offen gelten). Andernfalls: nächster Turnus danach.
    func seed(
        afterLatestPayment latestPayment: Date,
        in period: DateInterval,
        cadence: RecurringCommitment.Cadence,
        calendar: Calendar
    ) -> Date? {
        if period.containsHalfOpen(latestPayment) { return latestPayment }
        return nextDate(after: latestPayment, cadence: cadence, calendar: calendar)
    }

    /// Fälligkeit in einem Zeitraum: ob ein Termin im Intervall liegt.
    func isDue(
        for commitment: RecurringCommitment,
        in interval: DateInterval,
        calendar: Calendar
    ) -> Bool {
        !occurrences(for: commitment, in: interval, calendar: calendar).isEmpty
    }

    /// Monthly-Equivalent-Divisor für Summen (WP6 nutzt diesen, um z. B.
    /// yearly → /12 zu normalisieren): monthlyEquivalent = amount ÷ divisor.
    /// Reine Mathematik, kein Datum.
    func monthlyEquivalentDivisor(cadence: RecurringCommitment.Cadence) -> Decimal {
        switch cadence {
        case .weekly: Decimal(string: "12.0")! / 52  // ×52/12 pro Monat
        case .monthly: 1
        case .quarterly: 3
        case .yearly: 12
        }
    }

    // MARK: - Private

    /// Seed für die Occurrence-Generierung: das früheste bekannte Datum,
    /// gespeicherte Planung falls im Intervall beginnend, sonst Monatsstart
    /// zurücksetzen, bis der Cursor vor das Intervall geht.
    private func seedDate(
        for commitment: RecurringCommitment,
        in interval: DateInterval,
        calendar: Calendar
    ) -> Date? {
        // Stored plan ist die stärkste Quelle, sofern sie in die Zukunft
        // des Intervalls zeigt.
        if let stored = commitment.nextExpectedDate, stored >= interval.start {
            return stored
        }

        // Rückwärts vom Intervallstart zu einem sicheren Seed: wir gehen so
        // lange einen Turnus zurück, bis der Cursor VOR dem Intervall liegt.
        let anchor = commitment.nextExpectedDate ?? interval.start
        var cursor = anchor
        var steps = 0
        while let previous = previousDate(before: cursor, cadence: commitment.cadence, calendar: calendar),
              previous >= interval.start, steps < 1_000 {
            cursor = previous
            steps += 1
        }
        // Cursor liegt jetzt vor dem Intervallstart oder kann nicht weiter
        // zurück: er ist der erste Kandidat, der forward-geprüft wird.
        return cursor
    }

    private func previousDate(
        before date: Date,
        cadence: RecurringCommitment.Cadence,
        calendar: Calendar
    ) -> Date? {
        switch cadence {
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: -1, to: date)
        case .monthly:
            return calendar.date(byAdding: .month, value: -1, to: date)
        case .quarterly:
            return calendar.date(byAdding: .month, value: -3, to: date)
        case .yearly:
            return calendar.date(byAdding: .year, value: -1, to: date)
        }
    }

    /// Monats-Add mit stabilen Day-Anchors.
    ///
    /// `Calendar.date(byAdding: .month)` clamp'd bereits (31.01. + 1 Monat =
    /// 28.02.), aber der Anchor "wandert" dann auf 28. Für EOM-Commitments
    /// (letzter gültiger Tag) bleibt der Anchor deshalb pro Schritt am
    /// Monatsende verankert: 28.02. + 1 Monat → 31.03.
    ///
    /// Gilt für alle Monats-basierten Cadences (monthly/quarterly/yearly).
    private func advanced(byMonths months: Int, from date: Date, calendar: Calendar) -> Date? {
        let next = calendar.date(byAdding: .month, value: months, to: date)
        guard let next else { return nil }

        guard isLastDayOfMonth(date, calendar: calendar) else { return next }

        // Anchor bleibt am Monatsende.
        let dayComponent = calendar.component(.day, from: next)
        let range = calendar.range(of: .day, in: .month, for: next)
        guard let range, dayComponent < range.count else { return next }
        var components = calendar.dateComponents([.year, .month], from: next)
        components.day = range.count
        return calendar.date(from: components)
    }

    private func isLastDayOfMonth(_ date: Date, calendar: Calendar) -> Bool {
        let day = calendar.component(.day, from: date)
        let range = calendar.range(of: .day, in: .month, for: date)
        return range.map { day == $0.count } ?? false
    }
}
