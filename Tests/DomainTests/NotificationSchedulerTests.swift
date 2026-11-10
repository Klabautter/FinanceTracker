import Foundation
import Testing

@testable import FinanceTracker

@Suite("NotificationScheduler")
struct NotificationSchedulerTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var fixedNow: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 15
        components.hour = 12
        components.timeZone = TimeZone(identifier: "UTC")
        return utcCalendar.date(from: components)!
    }

    private var monthInterval: DateInterval {
        let start = utcCalendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let end = utcCalendar.date(byAdding: .month, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    private func progress(name: String, spent: String, limit: String) -> BudgetProgress {
        BudgetProgress(
            budget: Budget(name: name, amount: Decimal(string: limit)!),
            spent: Decimal(string: spent)!,
            currency: .eur,
            period: monthInterval
        )
    }

    private func commitment(name: String, dueInDays: Int?, status: RecurringCommitment.Status = .active) -> RecurringCommitment {
        let due = dueInDays.map { utcCalendar.date(byAdding: .day, value: $0, to: fixedNow)! }
        return RecurringCommitment(
            name: name,
            direction: .expense,
            expectedAmount: Decimal(string: "50")!,
            nextExpectedDate: due,
            status: status
        )
    }

    @Test("Budget 80 % warnt, 79 % bleibt still")
    func budgetWarningThreshold() {
        let scheduler = NotificationScheduler()
        let warning = scheduler.makeNotifications(
            budgetProgresses: [progress(name: "Essen", spent: "80", limit: "100")],
            commitments: [],
            syncIssues: [],
            now: fixedNow,
            calendar: utcCalendar
        )
        #expect(warning.count == 1)
        #expect(warning[0].kind == .budgetWarning80)

        let silent = scheduler.makeNotifications(
            budgetProgresses: [progress(name: "Essen", spent: "79", limit: "100")],
            commitments: [],
            syncIssues: [],
            now: fixedNow,
            calendar: utcCalendar
        )
        #expect(silent.isEmpty)
    }

    @Test("Budget 100 % und darüber meldet überschritten (nicht Warnung)")
    func budgetExceeded() {
        let scheduler = NotificationScheduler()
        for spent in ["100", "150"] {
            let result = scheduler.makeNotifications(
                budgetProgresses: [progress(name: "Essen", spent: spent, limit: "100")],
                commitments: [],
                syncIssues: [],
                now: fixedNow,
                calendar: utcCalendar
            )
            #expect(result.count == 1)
            #expect(result[0].kind == .budgetExceeded100)
        }
    }

    @Test("Null-Limit erzeugt keine Mitteilung")
    func zeroLimitSilent() {
        let scheduler = NotificationScheduler()
        let result = scheduler.makeNotifications(
            budgetProgresses: [progress(name: "Leer", spent: "10", limit: "0")],
            commitments: [],
            syncIssues: [],
            now: fixedNow,
            calendar: utcCalendar
        )
        #expect(result.isEmpty)
    }

    @Test("Fixkosten fällig in 3 Tagen: 4 Tage bleibt still, pausiert bleibt still")
    func commitmentWindow() {
        let scheduler = NotificationScheduler()
        let due = scheduler.makeNotifications(
            budgetProgresses: [],
            commitments: [commitment(name: "Miete", dueInDays: 3)],
            syncIssues: [],
            now: fixedNow,
            calendar: utcCalendar
        )
        #expect(due.count == 1)
        #expect(due[0].kind == .commitmentDueSoon)

        let far = scheduler.makeNotifications(
            budgetProgresses: [],
            commitments: [commitment(name: "Miete", dueInDays: 4)],
            syncIssues: [],
            now: fixedNow,
            calendar: utcCalendar
        )
        #expect(far.isEmpty)

        let paused = scheduler.makeNotifications(
            budgetProgresses: [],
            commitments: [commitment(name: "Miete", dueInDays: 1, status: .paused)],
            syncIssues: [],
            now: fixedNow,
            calendar: utcCalendar
        )
        #expect(paused.isEmpty)
    }

    @Test("Fällig heute/morgen formuliert exakt")
    func commitmentWording() {
        let scheduler = NotificationScheduler()
        let today = scheduler.makeNotifications(
            budgetProgresses: [],
            commitments: [commitment(name: "Strom", dueInDays: 0)],
            syncIssues: [],
            now: fixedNow,
            calendar: utcCalendar
        )
        #expect(today[0].body.contains("heute"))

        let tomorrow = scheduler.makeNotifications(
            budgetProgresses: [],
            commitments: [commitment(name: "Strom", dueInDays: 1)],
            syncIssues: [],
            now: fixedNow,
            calendar: utcCalendar
        )
        #expect(tomorrow[0].body.contains("morgen"))
    }

    @Test("Sync-Fehler enthält Hinweis auf fehlenden Hintergrund-Sync ohne Consent")
    func syncIssueHint() {
        let scheduler = NotificationScheduler()
        let issue = NotificationSyncIssue(connectionID: UUID(), providerDisplayName: "Enable Banking")
        let result = scheduler.makeNotifications(
            budgetProgresses: [],
            commitments: [],
            syncIssues: [issue],
            now: fixedNow,
            calendar: utcCalendar
        )
        #expect(result.count == 1)
        #expect(result[0].kind == .syncIssue)
        #expect(result[0].body.contains("ohne deine Zustimmung"))
        #expect(result[0].body.contains("Enable Banking"))
    }

    @Test("Leere Eingaben erzeugen keine Mitteilungen; IDs sind stabil")
    func emptyAndStableIDs() {
        let scheduler = NotificationScheduler()
        #expect(scheduler.makeNotifications(budgetProgresses: [], commitments: [], syncIssues: [], now: fixedNow, calendar: utcCalendar).isEmpty)

        let budgets = [progress(name: "Essen", spent: "90", limit: "100")]
        let first = scheduler.makeNotifications(budgetProgresses: budgets, commitments: [], syncIssues: [], now: fixedNow, calendar: utcCalendar)
        let second = scheduler.makeNotifications(budgetProgresses: budgets, commitments: [], syncIssues: [], now: fixedNow, calendar: utcCalendar)
        #expect(first.map(\.id) == second.map(\.id))
    }
}

extension NotificationSchedulerTests {
    @Test("Ablauf-Erinnerung sieben Tage vorher und am Ablauftag, nur künftige Termine")
    func consentReminders() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12)))
        let expiry = try #require(calendar.date(from: DateComponents(year: 2027, month: 2, day: 8, hour: 18)))
        func connection(expiresAt: Date?, status: ConnectionStatus = .active) -> Connection {
            Connection(id: UUID(), userID: UUID(), provider: .enablebanking, providerConnectionID: "s",
                       institutionID: "DE|Trade Republic", status: status, consentExpiresAt: expiresAt,
                       lastSuccessfulSyncAt: now, createdAt: now, updatedAt: now)
        }
        let reminders = NotificationScheduler().consentReminders(for: [connection(expiresAt: expiry)], now: now, calendar: calendar)
        #expect(reminders.map(\.fireDate) == [
            calendar.date(from: DateComponents(year: 2027, month: 2, day: 1, hour: 10)),
            calendar.date(from: DateComponents(year: 2027, month: 2, day: 8, hour: 10))
        ])
        #expect(reminders.allSatisfy { $0.kind == .consentExpiring && $0.id.hasPrefix(NotificationScheduler.consentReminderIDPrefix) })

        // Drei Tage vor Ablauf: nur noch die Erinnerung am Ablauftag.
        let soon = try #require(calendar.date(byAdding: .day, value: 3, to: now))
        #expect(NotificationScheduler().consentReminders(for: [connection(expiresAt: soon)], now: now, calendar: calendar).count == 1)
        // Ohne Ablaufdatum oder getrennt: keine Erinnerung.
        #expect(NotificationScheduler().consentReminders(for: [connection(expiresAt: nil), connection(expiresAt: expiry, status: .disconnected)], now: now, calendar: calendar).isEmpty)
    }
}
