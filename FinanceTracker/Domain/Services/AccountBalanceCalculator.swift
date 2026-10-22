import Foundation

/// Kontostand aus Anfangsbestand plus Bewegungen ab dem Stichtag.
///
/// Semantik: `openingBalance` ist der Stand zu **Beginn** des Tages
/// `openingDate`; Buchungen an diesem Tag und danach verändern ihn.
/// Buchungen davor stecken bereits im Anfangsbestand. Ohne Stichtag zählen
/// alle Bewegungen. Ohne Anfangsbestand gibt es keinen Stand (`nil`):
/// die App zeigt dann nur die Netto-Bewegung (kein erfundener
/// Kontostand).
enum AccountBalanceCalculator {
    struct Movement: Sendable, Equatable {
        let date: Date
        let amount: Decimal
    }

    static func balance(
        openingBalance: Decimal?,
        openingDate: Date?,
        movements: [Movement],
        calendar: Calendar = .current
    ) -> Decimal? {
        guard let openingBalance else { return nil }
        let start = openingDate.map { calendar.startOfDay(for: $0) }
        return movements.reduce(openingBalance) { partial, movement in
            if let start, movement.date < start { return partial }
            return partial + movement.amount
        }
    }
}
