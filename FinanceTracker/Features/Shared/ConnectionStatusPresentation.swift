import Foundation

/// Die EINE Ableitung des Verbindungsstatus für Badges und Aktionen:
/// Konten-Seite und Bankverbindungen zeigen denselben Zustand aus
/// `ConnectionHealthEvaluator`, statt je eigene Regeln über `status`,
/// `consentExpiresAt` und `lastSuccessfulSyncAt` zu bauen.
enum ConnectionStatusPresentation {
    /// Nach so vielen Tagen ohne erfolgreichen Abruf gilt eine aktive
    /// Verbindung als veraltet; „Verbunden“ in Grün wäre dann irreführend.
    static let staleAfterDays = 7

    static func isStale(_ connection: Connection, now: Date = Date()) -> Bool {
        guard connection.status == .active,
              let last = connection.lastSuccessfulSyncAt else { return false }
        return now.timeIntervalSince(last) > TimeInterval(staleAfterDays) * 24 * 60 * 60
    }

    /// Abgelaufen ist auch, was heute schon abgelaufen ist: Der Evaluator
    /// rechnet in Tagen (Banner „läuft heute ab“), das Badge in Augenblicken.
    static func isExpired(_ connection: Connection, health: ConnectionHealth, now: Date) -> Bool {
        if case .expired = health { return true }
        return connection.consentExpiresAt.map { $0 < now } ?? false
    }

    static func label(for connection: Connection, health: ConnectionHealth, now: Date = Date()) -> String {
        if isExpired(connection, health: health, now: now), health != .blocked {
            return String(localized: "Zustimmung abgelaufen")
        }
        switch health {
        case .expired:
            return String(localized: "Zustimmung abgelaufen")
        case .blocked:
            return connection.status == .revoked
                ? String(localized: "Zugriff widerrufen")
                : String(localized: "Getrennt")
        case .noConsentInfo, .healthy, .expiring:
            break
        }
        if isStale(connection, now: now) {
            return String(localized: "Daten veraltet")
        }
        switch connection.status {
        case .active: return String(localized: "Verbunden")
        case .pendingAuthorization: return String(localized: "Autorisierung offen")
        case .expired: return String(localized: "Abgelaufen")
        case .revoked: return String(localized: "Zugriff widerrufen")
        case .disconnected: return String(localized: "Getrennt")
        }
    }

    static func needsReconnect(_ connection: Connection, health: ConnectionHealth, now: Date = Date()) -> Bool {
        if isExpired(connection, health: health, now: now) { return true }
        switch health {
        case .expired, .blocked: return true
        case .noConsentInfo, .healthy, .expiring: return connection.status != .active
        }
    }
}
