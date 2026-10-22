import Foundation

/// WP7 (§54-58): Occurrence-Level-Resolution für wiederkehrende Zahlungen.
///
/// Statt eines groben Commitment-Level-Paid-Flags wird jedes geplante
/// Vorkommen einzeln aufgelöst:
///
///     Scheduled Occurrences ↔ Explicit User Assignments ↔ Heuristic Matches
///
/// Zuordnungsreihenfolge (§57): 1. explizite Nutzerzuordnung, 2. starke
/// Heuristik innerhalb des Toleranzfensters, 3. offen. Eine echte
/// Transaktion darf nie zwei Occurrences bezahlen (§56).

/// WP7 (§55): Deterministischer Key (commitmentID + tag-normalisiertes
/// Planungsdatum) statt zufälliger UUID.
struct RecurringOccurrenceKey: Hashable, Sendable, Codable {
    let commitmentID: UUID
    let scheduledDate: Date

    init(commitmentID: UUID, scheduledDate: Date, calendar: Calendar = .current) {
        self.commitmentID = commitmentID
        self.scheduledDate = calendar.startOfDay(for: scheduledDate)
    }
}

struct ScheduledRecurringOccurrence: Identifiable, Sendable, Equatable {
    enum MatchOrigin: Sendable, Equatable {
        /// Explizite Nutzerzuordnung: authoritative (§57).
        case explicitUserAssignment
        /// Heuristischer Match im Toleranzfenster.
        case heuristicMatch
        /// Fällig, aber nicht bezahlt.
        case open
    }

    let id: RecurringOccurrenceKey
    let commitmentID: UUID
    let scheduledDate: Date
    let expectedAmount: Decimal
    let currency: CurrencyCode
    let matchedTransactionID: UUID?
    let matchOrigin: MatchOrigin

    /// Fälligkeitstag liegt vor heute und der Termin ist nicht bezahlt.
    func isOverdue(now: Date, calendar: Calendar = .current) -> Bool {
        !isPaid && scheduledDate < calendar.startOfDay(for: now)
    }

    var isPaid: Bool { matchedTransactionID != nil }
}

/// Resolution eines Commitments für einen Zeitraum. Alle Beträge in der
/// Commitment-Währung: Währungstrennung passiert bei der Aggregation.
struct RecurringOccurrenceResolution: Sendable, Equatable {
    let scheduled: [ScheduledRecurringOccurrence]

    /// Fällig im Zeitraum (alle geplanten Vorkommen).
    var dueAmount: Decimal {
        scheduled.reduce(into: Decimal(0)) { $0 += $1.expectedAmount }
    }

    /// Bezahlt im Zeitraum (Vorkommen mit zugeordneter Transaktion).
    var paidAmount: Decimal {
        scheduled.filter(\.isPaid).reduce(into: Decimal(0)) { $0 += $1.expectedAmount }
    }

    /// Noch offen im Zeitraum.
    var openAmount: Decimal {
        dueAmount - paidAmount
    }

    var paidCount: Int {
        scheduled.filter(\.isPaid).count
    }

    var explicitlyAssignedCount: Int {
        scheduled.filter { $0.matchOrigin == .explicitUserAssignment }.count
    }

    /// Transaktionen, die im Zeitraum als Zahlung gelten (nach Datum sortiert).
    var paidTransactions: [Transaction] {
        scheduled
            .compactMap { occurrence in
                guard let transactionID = occurrence.matchedTransactionID else { return nil }
                return scheduledTransactionByID[transactionID]
            }
            .sorted { $0.displayDate < $1.displayDate }
    }

    /// Interne Lookup-Tabelle (nicht Teil der Equatable-Semantik).
    private var scheduledTransactionByID: [UUID: Transaction] = [:]

    init(scheduled: [ScheduledRecurringOccurrence], transactionsByID: [UUID: Transaction] = [:]) {
        self.scheduled = scheduled
        self.scheduledTransactionByID = transactionsByID
    }

    static func == (lhs: RecurringOccurrenceResolution, rhs: RecurringOccurrenceResolution) -> Bool {
        lhs.scheduled == rhs.scheduled
    }
}

extension RecurringOccurrenceResolver {

    /// So viele Tage bleibt ein unbezahlter Termin nach seinem Fälligkeitstag
    /// noch als „überfällig" in der Vorschau sichtbar.
    static let overdueGraceDays = 7

    /// Offene Vorkommen für „Anstehend": alle unbezahlten Termine bis `end`
    /// sowie überfällige der letzten `overdueGraceDays` Tage. Ein gestern
    /// fälliger, nicht bezahlter Termin verschwindet so nicht kommentarlos.
    ///
    /// Aufgelöst wird über das doppelte Rückschaufenster, damit eine kurz vor
    /// dem Termin eingegangene Zahlung ihn weiterhin als bezahlt markiert.
    func openOccurrences(
        commitment: RecurringCommitment,
        explicitOccurrences: [RecurringOccurrence],
        allTransactions: [Transaction],
        now: Date,
        end: Date,
        calendar: Calendar = .current,
        latestPaymentDate: Date? = nil
    ) -> [ScheduledRecurringOccurrence] {
        let today = calendar.startOfDay(for: now)
        guard let visibleFrom = calendar.date(byAdding: .day, value: -Self.overdueGraceDays, to: today),
              let resolveFrom = calendar.date(byAdding: .day, value: -2 * Self.overdueGraceDays, to: today),
              resolveFrom < end else {
            return []
        }
        return resolveOccurrences(
            commitment: commitment,
            explicitOccurrences: explicitOccurrences,
            allTransactions: allTransactions,
            period: DateInterval(start: resolveFrom, end: end),
            calendar: calendar,
            latestPaymentDate: latestPaymentDate
        )
        .scheduled
        .filter { !$0.isPaid && $0.scheduledDate >= visibleFrom }
    }

    /// WP7 (§56-57): Occurrence-basierte Resolution eines Commitments.
    ///
    /// Heuristik-Regel: Kandidaten liegen in `period`; die Zuordnung aufs
    /// zeitlich nächste freie Vorkommen ist auf einen vollen Turnus-Schritt
    /// begrenzt. Dadurch bezahlt eine Zahlung aus dem VORMONAT kein
    /// Vorkommen des aktuellen Zyklus, eine vorzeitige Zahlung innerhalb
    /// des Zyklus aber schon.
    ///
    /// - Parameters:
    ///   - period: Zeitraum, für den geplante Vorkommen aufgelöst werden.
    ///   - latestPaymentDate: Datum der letzten bekannten realen Zahlung,
    ///     dient als Schedule-Seed, damit wöchentliche/monatliche Termine am
    ///     realen Rhythmus hängen (nicht an einem arbiträren Intervallstart).
    ///   - explicitOccurrences: alle manuellen Zuordnungen des Commitments.
    func resolveOccurrences(
        commitment: RecurringCommitment,
        explicitOccurrences: [RecurringOccurrence],
        allTransactions: [Transaction],
        period: DateInterval,
        calendar: Calendar = .current,
        latestPaymentDate: Date? = nil
    ) -> RecurringOccurrenceResolution {
        // 1) Geplante Vorkommen im Zeitraum generieren. Seed: letzte reale
        //    Zahlung → nächster Turnus; sonst gespeicherte Planung.
        var planned = commitment
        if let latestPaymentDate {
            planned.nextExpectedDate = RecurringScheduleService().seed(
                afterLatestPayment: latestPaymentDate,
                in: period,
                cadence: commitment.cadence,
                calendar: calendar
            ) ?? commitment.nextExpectedDate
        }
        let scheduledDates = RecurringScheduleService().occurrences(
            for: planned,
            in: period,
            calendar: calendar
        )

        // Transaktionen nach ID (keine Doppelvergabe möglich, §56), nur die
        // explizit zugeordneten; ein Index über alle Buchungen je Fixkost
        // kostete bei großen Beständen Sekunden.
        let explicitIDs = Set(explicitOccurrences.map(\.transactionID))
        let transactionsByID = explicitIDs.isEmpty ? [:] : Dictionary(
            allTransactions.lazy.filter { explicitIDs.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var usedTransactionIDs = Set<UUID>()

        // 2) Explizite Nutzerzuordnungen zuerst (authoritative, §57).
        //    Eine Transaktion zugeordnet: einmal.
        var explicitTxnIDs = Set<UUID>()
        for occurrence in explicitOccurrences {
            guard transactionsByID[occurrence.transactionID] != nil else { continue }
            explicitTxnIDs.insert(occurrence.transactionID)
        }
        usedTransactionIDs.formUnion(explicitTxnIDs)

        // Zuordnung: jede explizite Transaktion auf das zeitlich nächste
        // FREIE geplante Vorkommen im Zeitraum. Die Nutzer-Entscheidung ist
        // authoritative, kein Toleranz-Limit (anders als bei der Heuristik).
        var assignedExplicit: [RecurringOccurrenceKey: UUID] = [:]
        for transactionID in explicitTxnIDs.sorted(by: {
            (transactionsByID[$0]?.displayDate ?? .distantPast)
                < (transactionsByID[$1]?.displayDate ?? .distantPast)
        }) {
            guard let txn = transactionsByID[transactionID] else { continue }
            let candidates = scheduledDates
                .filter { date in
                    assignedExplicit[RecurringOccurrenceKey(
                        commitmentID: commitment.id,
                        scheduledDate: date,
                        calendar: calendar
                    )] == nil
                }
                .sorted { abs($0.distance(to: txn.displayDate)) < abs($1.distance(to: txn.displayDate)) }
            if let nearest = candidates.first {
                assignedExplicit[RecurringOccurrenceKey(
                    commitmentID: commitment.id,
                    scheduledDate: nearest,
                    calendar: calendar
                )] = transactionID
            }
        }

        // 3) Heuristik für verbleibende offene Vorkommen: Kandidaten nur
        //    aus dem Zeitraum, Zuordnung aufs zeitlich nächste freie
        //    Vorkommen innerhalb eines vollen Turnus-Schritts. Jede
        //    Transaktion nur einmal (§56).
        let heuristicCandidates = RecurringPaymentMatcher.matchingTransactions(
            for: commitment,
            in: allTransactions,
            calendar: calendar
        )
        .filter { period.containsHalfOpen($0.displayDate) }
        .filter { !usedTransactionIDs.contains($0.id) }
        .sorted { $0.displayDate < $1.displayDate }

        let stepWindow = Self.cadenceStepDays(for: commitment.cadence)
        var assignedHeuristic: [RecurringOccurrenceKey: UUID] = [:]
        for date in scheduledDates {
            let key = RecurringOccurrenceKey(
                commitmentID: commitment.id,
                scheduledDate: date,
                calendar: calendar
            )
            guard assignedExplicit[key] == nil else { continue }
            guard let match = heuristicCandidates.first(where: { txn in
                !usedTransactionIDs.contains(txn.id)
                    && abs(txn.displayDate.distance(to: date)) <= stepWindow
            }) else { continue }
            assignedHeuristic[key] = match.id
            usedTransactionIDs.insert(match.id)
        }

        // 4) Resultat aufbauen.
        let scheduled: [ScheduledRecurringOccurrence] = scheduledDates.map { date in
            let key = RecurringOccurrenceKey(
                commitmentID: commitment.id,
                scheduledDate: date,
                calendar: calendar
            )
            if let txnID = assignedExplicit[key] {
                return ScheduledRecurringOccurrence(
                    id: key,
                    commitmentID: commitment.id,
                    scheduledDate: date,
                    expectedAmount: commitment.expectedAmount,
                    currency: commitment.currency,
                    matchedTransactionID: txnID,
                    matchOrigin: .explicitUserAssignment
                )
            }
            if let txnID = assignedHeuristic[key] {
                return ScheduledRecurringOccurrence(
                    id: key,
                    commitmentID: commitment.id,
                    scheduledDate: date,
                    expectedAmount: commitment.expectedAmount,
                    currency: commitment.currency,
                    matchedTransactionID: txnID,
                    matchOrigin: .heuristicMatch
                )
            }
            return ScheduledRecurringOccurrence(
                id: key,
                commitmentID: commitment.id,
                scheduledDate: date,
                expectedAmount: commitment.expectedAmount,
                currency: commitment.currency,
                matchedTransactionID: nil,
                matchOrigin: .open
            )
        }

        return RecurringOccurrenceResolution(
            scheduled: scheduled,
            transactionsByID: transactionsByID
        )
    }

    private static func cadenceStepDays(for cadence: RecurringCommitment.Cadence) -> TimeInterval {
        switch cadence {
        case .weekly: 7 * 86_400
        case .monthly: 31 * 86_400
        case .quarterly: 92 * 86_400
        case .yearly: 366 * 86_400
        }
    }
}
