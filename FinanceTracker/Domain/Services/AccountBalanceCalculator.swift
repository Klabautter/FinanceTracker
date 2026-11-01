import Foundation

/// Kontostand aus gemeldetem Stand oder Anfangsbestand plus Bewegungen.
///
/// Gemeldeter Stand (Bank oder Kontoauszug) hat Vorrang: Er gilt zum
/// Zeitpunkt `asOf`, nur spätere Bewegungen verändern ihn noch.
///
/// Anfangsbestand: Stand zu **Beginn** des Tages `openingDate`; Buchungen
/// an diesem Tag und danach verändern ihn, Buchungen davor stecken bereits
/// darin. Ohne Stichtag zählen alle Bewegungen.
///
/// Ohne beides gibt es keinen Stand (`nil`): die App zeigt dann nur die
/// Netto-Bewegung (kein erfundener Kontostand).
enum AccountBalanceCalculator {
    struct Movement: Sendable, Equatable {
        let date: Date
        let amount: Decimal
    }

    enum Basis: Sendable, Hashable {
        case reported(ReportedBalance.Source)
        case openingBalance
    }

    struct Result: Sendable, Hashable {
        let amount: Decimal
        let basis: Basis
        /// Zeitpunkt des gemeldeten Stands; beim Anfangsbestand `nil`.
        let reportedAt: Date?
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

    /// `movements` in Kontowährung. Ein gemeldeter Stand in anderer Währung
    /// als das Konto wird nicht verrechnet (#19), dann zählt der
    /// Anfangsbestand.
    static func balance(
        for account: Account,
        movements: [Movement],
        calendar: Calendar = .current
    ) -> Result? {
        if let reported = account.reportedBalance, reported.amount.currency == account.currency {
            let amount = movements.reduce(reported.amount.amount) { partial, movement in
                movement.date > reported.asOf ? partial + movement.amount : partial
            }
            return Result(amount: amount, basis: .reported(reported.source), reportedAt: reported.asOf)
        }
        return balance(
            openingBalance: account.openingBalance,
            openingDate: account.openingBalanceDate,
            movements: movements,
            calendar: calendar
        ).map { Result(amount: $0, basis: .openingBalance, reportedAt: nil) }
    }
}
