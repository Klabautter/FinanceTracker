import Foundation

/// WP5: Manuelle Occurrences sind authoritative.
///
/// Der Resolver verbindet Commitment, explizite Nutzer-Zuordnungen
/// (`RecurringOccurrence`) und Transaktionen zu einem Paid-Status:
///
/// - Explizite Zuordnung im Zeitraum gewinnt **immer** gegen die Heuristik,
///   auch bei Merchant-/Betrags-Abweichung (User choice wins).
/// - Ohne explizite Zuordnung im Zeitraum: heuristischer Fallback
///   (`RecurringPaymentMatcher`, nur mit merchantKey), sonst offen.
/// - Der Display-Name fließt nie in das Matching ein (WP4).
struct RecurringOccurrenceResolver: Sendable {
    struct Result: Sendable, Equatable {
        /// Transaktionen, die im Zeitraum als Zahlung gelten.
        let matchedTransactions: [Transaction]
        /// `true`, wenn die Zahlung(en) explizit vom Nutzer zugeordnet sind.
        let isExplicitlyAssigned: Bool
        /// Datum der letzten gültigen Zahlung (über alle Zeiträume).
        let latestOccurrence: Date?
    }

    /// Löst den Paid-Status eines Commitments für `period` auf.
    ///
    /// - Parameters:
    ///   - allTransactions: Transaktionen im Blick (i. d. R. der Period +
    ///     Historie); der Resolver filtert auf `period`.
    ///   - explicitOccurrences: alle manuellen Zuordnungen des Commitments.
    func resolve(
        commitment: RecurringCommitment,
        explicitOccurrences: [RecurringOccurrence],
        allTransactions: [Transaction],
        period: DateInterval,
        calendar: Calendar = .current
    ) -> Result {
        // Nur die explizit zugeordneten Buchungen indizieren (große Bestände).
        let explicitIDs = Set(explicitOccurrences.map(\.transactionID))
        let transactionsByID = explicitIDs.isEmpty ? [:] : Dictionary(
            allTransactions.lazy.filter { explicitIDs.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let explicitInPeriod = explicitOccurrences.compactMap { occurrence -> Transaction? in
            guard let txn = transactionsByID[occurrence.transactionID] else { return nil }
            guard period.containsHalfOpen(txn.displayDate) else { return nil }
            return txn
        }
        .sorted { $0.displayDate < $1.displayDate }

        if !explicitInPeriod.isEmpty {
            // Authoritative: auch bei Merchant-/Betrags-Mismatch zählt die
            // explizite Nutzer-Entscheidung.
            return Result(
                matchedTransactions: explicitInPeriod,
                isExplicitlyAssigned: true,
                latestOccurrence: explicitInPeriod.last?.displayDate
            )
        }

        // Fallback: Heuristik nur über merchantKey (WP4), nie über Namen.
        let heuristic = RecurringPaymentMatcher.matchingTransactions(
            for: commitment,
            in: allTransactions.filter { period.containsHalfOpen($0.displayDate) },
            calendar: calendar
        )
        .sorted { $0.displayDate < $1.displayDate }

        let latest = explicitOccurrences.compactMap { occurrence -> Date? in
            transactionsByID[occurrence.transactionID]?.displayDate
        }.max()

        return Result(
            matchedTransactions: heuristic,
            isExplicitlyAssigned: false,
            latestOccurrence: latest ?? heuristic.last?.displayDate
        )
    }
}
