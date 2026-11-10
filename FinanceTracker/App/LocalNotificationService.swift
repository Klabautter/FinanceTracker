import Foundation
import UserNotifications

/// Plattform-Anbindung für lokale Mitteilungen (Opt-in, lesend).
///
/// Die Regel-Auswertung (`NotificationScheduler`, Domain) bleibt rein und
/// testbar; hier liegt nur die `UserNotifications`-Übermittlung an der
/// App-Grenze (#9: `#if os` nur hier, nicht in Domain/Data).
protocol LocalNotificationScheduling: Sendable {
    /// Fragt die System-Freigabe an (nur nach explizitem Opt-in aufgerufen).
    func requestAuthorization() async -> Bool
    /// Plant die übergebenen Hinweise (ersetzt gleiche IDs, kein Rescheduling
    /// ohne erneuten lokalen Aufruf; kein Hintergrund-Sync, #15).
    func schedule(_ notifications: [PendingLocalNotification]) async
    func clearAll() async
}

struct LocalNotificationService: LocalNotificationScheduling, Sendable {
    func requestAuthorization() async -> Bool {
        #if os(macOS)
        let options: UNAuthorizationOptions = [.alert, .sound]
        #else
        let options: UNAuthorizationOptions = [.alert, .badge, .sound]
        #endif
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: options)
        } catch {
            return false
        }
    }

    func schedule(_ notifications: [PendingLocalNotification]) async {
        guard !notifications.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: notifications.map(\.id))
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            #if os(macOS)
            content.sound = .default
            #else
            content.sound = .default
            content.badge = nil
            #endif
            var trigger: UNNotificationTrigger?
            if let fireDate = notification.fireDate, fireDate > Date() {
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            }
            let request = UNNotificationRequest(
                identifier: notification.id,
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    /// Plant nur die Ablauf-Erinnerungen neu (alte mit demselben Präfix
    /// fallen weg), ohne andere Hinweise erneut zuzustellen.
    func replaceConsentReminders(_ reminders: [PendingLocalNotification]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(NotificationScheduler.consentReminderIDPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        await schedule(reminders)
    }

    func clearAll() async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
