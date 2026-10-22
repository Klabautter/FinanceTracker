import Foundation

/// Art einer lokal geplanten Mitteilung (lesend, opt-in, kein Hintergrund-
/// Sync der Bank ohne Consent).
enum LocalNotificationKind: String, Sendable, Hashable, CaseIterable {
    case budgetWarning80
    case budgetExceeded100
    case commitmentDueSoon
    case syncIssue
}

/// Rein berechnete, noch nicht übermittelte Mitteilung. Die Übermittlung
/// (`UNUserNotificationCenter`) liegt an der App-Grenze
/// (`App/LocalNotificationService`), hier entsteht nur Inhalt + stabile ID.
struct PendingLocalNotification: Sendable, Hashable, Identifiable {
    let id: String
    let kind: LocalNotificationKind
    let title: String
    let body: String
}

/// Leichter Sync-Hinweis (kein Bank-Call, nur lokale Einstufung, z. B.
/// abgelaufene/blockierte Connection). Die IDs bleiben stabil, damit das
/// System Duplikate ersetzen kann.
struct NotificationSyncIssue: Sendable, Hashable {
    let connectionID: UUID
    let providerDisplayName: String

    init(connectionID: UUID, providerDisplayName: String) {
        self.connectionID = connectionID
        self.providerDisplayName = providerDisplayName
    }
}

/// Reine, testbare Scheduler-Regeln (Sendable, kein Singleton):
/// - Budget 80 % (Warnung) / 100 % (überschritten) über dieselbe
///   `BudgetProgress`-Semantik wie Budgets/Analytics/Forecast (#28).
/// - Fixkosten fällig in 3 Tagen (aktive Commitments mit `nextExpectedDate`
///   in 0...3 Tagen, startOfDay-stabil).
/// - Sync-Fehler als lokale Hinweise, mit dem Zusatz, dass ohne Zustimmung
///   kein Hintergrund-Sync stattfindet (#15 read-only).
struct NotificationScheduler: Sendable {
    /// Warnschwelle als Decimal (kein Double für Geld-/Schwellenlogik).
    var budgetWarningFraction: Decimal
    var commitmentDueWithinDays: Int

    init(budgetWarningFraction: Decimal = Decimal(string: "0.8")!, commitmentDueWithinDays: Int = 3) {
        self.budgetWarningFraction = budgetWarningFraction
        self.commitmentDueWithinDays = commitmentDueWithinDays
    }

    func makeNotifications(
        budgetProgresses: [BudgetProgress],
        commitments: [RecurringCommitment],
        syncIssues: [NotificationSyncIssue],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [PendingLocalNotification] {
        var result: [PendingLocalNotification] = []
        result.append(contentsOf: budgetNotifications(for: budgetProgresses))
        result.append(contentsOf: commitmentNotifications(for: commitments, now: now, calendar: calendar))
        result.append(contentsOf: syncIssues.map(syncNotification(for:)))
        return result
    }

    // MARK: - Budgets

    private func budgetNotifications(for progresses: [BudgetProgress]) -> [PendingLocalNotification] {
        var result: [PendingLocalNotification] = []
        for progress in progresses {
            let limit = progress.effectiveLimit
            guard limit > 0 else { continue }
            let name = progress.budget.name
            if progress.spent >= limit {
                result.append(PendingLocalNotification(
                    id: "budget-exceeded-\(progress.budget.id.uuidString)",
                    kind: .budgetExceeded100,
                    title: String(localized: "Budget überschritten"),
                    body: String(localized: "„\(name)“ hat das Limit erreicht.")
                ))
            } else if progress.spent >= limit * budgetWarningFraction {
                let percent = warningPercentLabel
                result.append(PendingLocalNotification(
                    id: "budget-warning-\(progress.budget.id.uuidString)",
                    kind: .budgetWarning80,
                    title: String(localized: "Budget fast ausgeschöpft"),
                    body: String(localized: "„\(name)“ ist zu \(percent) ausgeschöpft.")
                ))
            }
        }
        return result
    }

    private var warningPercentLabel: String {
        let percent = (NSDecimalNumber(decimal: budgetWarningFraction).doubleValue * 100).rounded()
        return "\(Int(percent)) %"
    }

    // MARK: - Fixkosten

    private func commitmentNotifications(
        for commitments: [RecurringCommitment],
        now: Date,
        calendar: Calendar
    ) -> [PendingLocalNotification] {
        let startToday = calendar.startOfDay(for: now)
        return commitments.compactMap { commitment in
            guard commitment.status == .active else { return nil }
            guard let due = commitment.nextExpectedDate else { return nil }
            let days = calendar.dateComponents([.day], from: startToday, to: calendar.startOfDay(for: due)).day ?? Int.max
            guard days >= 0, days <= commitmentDueWithinDays else { return nil }
            let title = commitment.direction == .expense ? String(localized: "Fixkosten fällig") : String(localized: "Wiederkehrende Einnahme erwartet")
            let body: String
            switch days {
            case 0: body = String(localized: "„\(commitment.name)“ ist heute fällig.")
            case 1: body = String(localized: "„\(commitment.name)“ ist morgen fällig.")
            default: body = String(localized: "„\(commitment.name)“ ist in \(days) Tagen fällig.")
            }
            return PendingLocalNotification(
                id: "commitment-due-\(commitment.id.uuidString)",
                kind: .commitmentDueSoon,
                title: title,
                body: body
            )
        }
    }

    // MARK: - Sync

    private func syncNotification(for issue: NotificationSyncIssue) -> PendingLocalNotification {
        PendingLocalNotification(
            id: "sync-\(issue.connectionID.uuidString)",
            kind: .syncIssue,
            title: String(localized: "Bank-Sync braucht Aufmerksamkeit"),
            body: String(localized: "„\(issue.providerDisplayName)“ konnte nicht synchronisiert werden. Öffne die App und erneuere den Zugang: ohne deine Zustimmung findet kein Hintergrund-Sync statt.")
        )
    }
}
