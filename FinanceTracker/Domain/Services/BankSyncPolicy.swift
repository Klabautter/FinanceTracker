import Foundation

/// Entscheidet, welche Bankverbindungen ein Sammelabruf anfasst (rein, kein
/// I/O, kein Singleton).
///
/// Banken erlauben ohne anwesenden Nutzer meist nur etwa vier Abrufe pro Tag
/// und Konto (PSD2 RTS Art. 36 Abs. 5). Der automatische Abruf hält deshalb
/// einen Mindestabstand ein; ein ausdrücklicher Klick gilt immer.
struct BankSyncPolicy: Sendable {
    enum Trigger: Equatable, Sendable {
        /// App-Start, Rückkehr in die App, Zeitprüfung im Hintergrund.
        case automatic
        /// „Alle aktualisieren“ durch den Nutzer.
        case manual
    }

    enum Decision: Equatable, Sendable {
        case sync
        /// Automatik: letzter Abruf oder Fehlversuch liegt zu kurz zurück.
        case notDue
        /// Zustimmung abgelaufen oder widerrufen: erst neu freigeben.
        case needsReauthorization
        /// Kein Abruf möglich oder gewollt (lokal, getrennt, Freigabe offen).
        case notSyncable
    }

    /// Warum ein Abrufversuch gescheitert ist (für die Wartezeit danach).
    enum AttemptFailure: Equatable, Sendable {
        /// Kein Netz (offline, gerade aufgewacht): bald erneut versuchen.
        case offline
        /// Bank oder Anbieter kurz gestört (5xx, 429, unlesbare Antwort).
        case transient
        /// Zugang abgelaufen, widerrufen oder Zugangsdaten fehlen: Von
        /// selbst wird das nicht besser.
        case needsUserAction
    }

    static let defaultMinimumInterval: TimeInterval = 6 * 60 * 60
    static let defaultRetryInterval: TimeInterval = 60 * 60
    static let defaultOfflineRetryInterval: TimeInterval = 10 * 60

    /// Mindestabstand zum letzten erfolgreichen Abruf (nur Automatik).
    let minimumInterval: TimeInterval
    /// Wartezeit nach dem ersten Fehlversuch (nur Automatik), damit ein
    /// Limit der Bank nicht bei jedem Fensterwechsel erneut getroffen wird.
    let retryInterval: TimeInterval
    /// Wartezeit, wenn nur das Netz fehlte.
    let offlineRetryInterval: TimeInterval

    init(
        minimumInterval: TimeInterval = BankSyncPolicy.defaultMinimumInterval,
        retryInterval: TimeInterval = BankSyncPolicy.defaultRetryInterval,
        offlineRetryInterval: TimeInterval = BankSyncPolicy.defaultOfflineRetryInterval
    ) {
        self.minimumInterval = minimumInterval
        self.retryInterval = retryInterval
        self.offlineRetryInterval = offlineRetryInterval
    }

    /// Wartezeit bis zum nächsten automatischen Versuch. Scheitert eine Bank
    /// wiederholt, gilt der volle Mindestabstand: Auch Fehlversuche zählen
    /// bei der Bank als Abruf. `nil`: von selbst gar nicht mehr.
    func automaticRetryDelay(after failure: AttemptFailure, consecutiveFailures: Int) -> TimeInterval? {
        switch failure {
        case .offline: offlineRetryInterval
        case .transient: consecutiveFailures <= 1 ? retryInterval : max(retryInterval, minimumInterval)
        case .needsUserAction: nil
        }
    }

    /// - Parameter automaticNotBefore: Frühester Zeitpunkt für den nächsten
    ///   automatischen Versuch nach einem Fehlversuch.
    func decision(
        for connection: Connection,
        trigger: Trigger,
        automaticNotBefore: Date? = nil,
        now: Date = Date()
    ) -> Decision {
        guard connection.provider.supportsRemoteSync,
              connection.providerConnectionID != nil else { return .notSyncable }

        switch connection.status {
        case .disconnected, .pendingAuthorization:
            return .notSyncable
        case .expired, .revoked:
            return .needsReauthorization
        case .active:
            break
        }
        if let expiresAt = connection.consentExpiresAt, expiresAt < now {
            return .needsReauthorization
        }

        guard trigger == .automatic else { return .sync }
        if let lastSync = connection.lastSuccessfulSyncAt,
           now.timeIntervalSince(lastSync) < minimumInterval {
            return .notDue
        }
        if let automaticNotBefore, now < automaticNotBefore {
            return .notDue
        }
        return .sync
    }
}

extension ConnectionProvider {
    /// Anbieter, über die die App Umsätze online abrufen kann.
    var supportsRemoteSync: Bool {
        switch self {
        case .enablebanking, .gocardless: true
        case .local, .tink, .future, .mock: false
        }
    }
}
