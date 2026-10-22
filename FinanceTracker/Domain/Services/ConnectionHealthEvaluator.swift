import Foundation

/// PSD2-Consent-Gesundheit (read-only, lokal ausgewertet).
///
/// - `validUntil` (Consent, typ. ~90 Tage): `Connection.consentExpiresAt`.
/// - SCA-Ausnahme nach RTS Art. 10 (max. 180 Tage ohne starke
///   Authentifizierung): approximiert über `lastSuccessfulSyncAt`, ist der
///   letzte erfolgreiche Sync länger als `scaMaxDays` her, ist mit einer
///   Re-Authentifizierung zu rechnen, auch wenn `consentExpiresAt` noch
///   gültig ist.
///
/// Die Auswertung ist rein (kein Netzwerk, kein Singleton) und damit
/// unit-testbar. UI-Texte entstehen in den Models/Views; der Evaluator
/// liefert nur Klassifikationen + Tageszahlen.
enum ConnectionHealth: Equatable, Sendable {
    /// Kein Ablaufdatum bekannt (z. B. lokale/Mock-Verbindung).
    case noConsentInfo
    case healthy(daysLeft: Int)
    /// Läuft in `daysLeft` Tagen ab (0...warningDays, inkl. heute).
    case expiring(daysLeft: Int)
    /// Abgelaufen (`overdueDays` >= 0, 0 = heute abgelaufen).
    case expired(overdueDays: Int)
    /// Widerrufen oder getrennt, kein Sync möglich, nur Neuverbindung.
    case blocked
}

/// 3-Wege-Klassifikation von Sync-Fehlern (P1-Vorgabe):
/// - `.transientRetry`: vorübergehend (Netz/5xx/429), stiller Retry bzw.
///   „Erneut versuchen“, kein Re-Connect nötig.
/// - `.reauthRequired`: Consent/SCA abgelaufen, Credentials fehlen oder 401/403,
///   „Jetzt erneuern“ (Re-Auth-Flow).
/// - `.blocked`: widerrufen/getrennt/geschlossen (404/410, Status revoked),
///   Neuverbindung nötig, alte Daten bleiben erhalten.
enum SyncFailureKind: String, Equatable, Sendable, CaseIterable {
    case transientRetry
    case reauthRequired
    case blocked
}

struct ConnectionHealthEvaluator: Sendable {
    /// T-10d-Banner („Zugang läuft ab“).
    let consentWarningDays: Int
    /// RTS Art. 10: max. 180 Tage ohne SCA.
    let scaMaxDays: Int

    init(consentWarningDays: Int = 10, scaMaxDays: Int = 180) {
        self.consentWarningDays = consentWarningDays
        self.scaMaxDays = scaMaxDays
    }

    // MARK: - Gesundheit

    func health(
        for connection: Connection,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ConnectionHealth {
        if connection.status == .revoked || connection.status == .disconnected {
            return .blocked
        }

        let consentHealth = consentHealth(
            expiresAt: connection.consentExpiresAt,
            now: now,
            calendar: calendar
        )
        let scaHealth = scaHealth(
            lastSyncAt: connection.lastSuccessfulSyncAt,
            now: now,
            calendar: calendar
        )
        return combined(consentHealth, scaHealth)
    }

    /// Verbindungen, die in den nächsten `consentWarningDays` ablaufen oder
    /// bereits abgelaufen sind (Banner-Quelle). Blockierte Verbindungen sind
    /// separat sichtbar und zählen hier nicht mit.
    func connectionsNeedingAttention(
        in connections: [Connection],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Connection] {
        connections.filter {
            switch health(for: $0, now: now, calendar: calendar) {
            case .expiring, .expired: true
            case .noConsentInfo, .healthy, .blocked: false
            }
        }
    }

    var bannerTitle: String { String(localized: "Zugang läuft ab") }

    func bannerMessage(for attentionConnections: [Connection], now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard !attentionConnections.isEmpty else { return nil }
        let soonest = attentionConnections.compactMap { connection -> Int? in
            switch health(for: connection, now: now, calendar: calendar) {
            case .expiring(let days): days
            case .expired: 0
            case .noConsentInfo, .healthy, .blocked: nil
            }
        }.min()
        if attentionConnections.count == 1, let days = soonest {
            if days <= 0 {
                return String(localized: "Ein Bankzugang ist abgelaufen oder läuft heute ab. Erneuere die Verbindung, um weiter zu synchronisieren.")
            }
            if days == 1 {
                return String(localized: "Ein Bankzugang läuft in 1 Tag ab. Erneuere die Verbindung rechtzeitig.")
            }
            return String(localized: "Ein Bankzugang läuft in \(days) Tagen ab. Erneuere die Verbindung rechtzeitig.")
        }
        return String(localized: "\(attentionConnections.count) Bankzugänge laufen in den nächsten \(consentWarningDays) Tagen ab oder sind abgelaufen.")
    }

    // MARK: - Sync-Fehler (3 Wege)

    func classify(syncError: Error, connection: Connection) -> SyncFailureKind {
        if connection.status == .revoked || connection.status == .disconnected {
            return .blocked
        }
        if let bankError = syncError as? BankProviderError {
            return classify(bankError: bankError)
        }
        if let importError = syncError as? ImportError {
            switch importError {
            case .unsupportedFormat(let reason)
                where reason == ImportError.connectionNotAuthorizedReason
                    || reason.localizedCaseInsensitiveContains("autorisier"):
                return .reauthRequired
            default:
                return .transientRetry
            }
        }
        return .transientRetry
    }

    private func classify(bankError: BankProviderError) -> SyncFailureKind {
        switch bankError {
        case .missingCredentials:
            return .reauthRequired
        case .invalidResponse:
            return .transientRetry
        case .requestFailed(_, let status, _):
            switch status {
            case 401, 403:
                return .reauthRequired
            case 404, 410:
                return .blocked
            case 408, 429:
                return .transientRetry
            case 500...599:
                return .transientRetry
            default:
                return .transientRetry
            }
        }
    }

    // MARK: - Privat

    private func consentHealth(expiresAt: Date?, now: Date, calendar: Calendar) -> ConnectionHealth {
        guard let expiresAt else { return .noConsentInfo }
        let days = days(from: now, to: expiresAt, calendar: calendar)
        if days < 0 { return .expired(overdueDays: -days) }
        if days <= consentWarningDays { return .expiring(daysLeft: days) }
        return .healthy(daysLeft: days)
    }

    private func scaHealth(lastSyncAt: Date?, now: Date, calendar: Calendar) -> ConnectionHealth {
        guard let lastSyncAt else { return .noConsentInfo }
        let daysSince = days(from: lastSyncAt, to: now, calendar: calendar)
        let remaining = scaMaxDays - daysSince
        if remaining < 0 { return .expired(overdueDays: -remaining) }
        if remaining <= consentWarningDays { return .expiring(daysLeft: remaining) }
        return .healthy(daysLeft: remaining)
    }

    private func combined(_ first: ConnectionHealth, _ second: ConnectionHealth) -> ConnectionHealth {
        // Blockiert dominiert immer (terminal).
        if first == .blocked || second == .blocked { return .blocked }
        // Abgelaufen dominiert „läuft ab“ dominiert Rest.
        switch (first, second) {
        case (.expired(let a), .expired(let b)): return .expired(overdueDays: max(a, b))
        case (.expired(let a), _): return .expired(overdueDays: a)
        case (_, .expired(let b)): return .expired(overdueDays: b)
        case (.expiring(let a), .expiring(let b)): return .expiring(daysLeft: min(a, b))
        case (.expiring(let a), _): return .expiring(daysLeft: a)
        case (_, .expiring(let b)): return .expiring(daysLeft: b)
        case (.healthy(let a), .healthy(let b)): return .healthy(daysLeft: min(a, b))
        case (.healthy(let a), .noConsentInfo): return .healthy(daysLeft: a)
        case (.noConsentInfo, .healthy(let b)): return .healthy(daysLeft: b)
        case (.noConsentInfo, .noConsentInfo): return .noConsentInfo
        case (.blocked, _), (_, .blocked): return .blocked
        }
    }

    /// Kalendertage zwischen zwei Zeitpunkten (startOfDay-basiert, damit
    /// Tagesgrenzen teststabil sind).
    private func days(from start: Date, to end: Date, calendar: Calendar) -> Int {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        return calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
    }
}
