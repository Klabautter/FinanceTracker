import Foundation
import Testing

@testable import FinanceTracker

@Suite("ConnectionHealthEvaluator")
struct ConnectionHealthEvaluatorTests {
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

    private func connection(
        status: ConnectionStatus = .active,
        expiresInDays: Int? = nil,
        lastSyncDaysAgo: Int? = nil
    ) -> Connection {
        let now = fixedNow
        let expires = expiresInDays.map { utcCalendar.date(byAdding: .day, value: $0, to: now)! }
        let lastSync = lastSyncDaysAgo.map { utcCalendar.date(byAdding: .day, value: -$0, to: now)! }
        return Connection(
            id: UUID(),
            userID: UUID(),
            provider: .enablebanking,
            providerConnectionID: "conn-1",
            institutionID: "inst-1",
            status: status,
            consentExpiresAt: expires,
            lastSuccessfulSyncAt: lastSync,
            createdAt: now,
            updatedAt: now
        )
    }

    @Test("Gesunde Verbindung bleibt gesund")
    func healthy() {
        let evaluator = ConnectionHealthEvaluator()
        let conn = connection(expiresInDays: 30, lastSyncDaysAgo: 1)
        guard case .healthy = evaluator.health(for: conn, now: fixedNow, calendar: utcCalendar) else {
            Issue.record("Expected healthy, got \(evaluator.health(for: conn, now: fixedNow, calendar: utcCalendar))")
            return
        }
    }

    @Test("T-10d-Schwelle: 10 Tage = expiring, 11 Tage = healthy")
    func warningThreshold() {
        let evaluator = ConnectionHealthEvaluator()
        let expiring = connection(expiresInDays: 10)
        guard case .expiring(let days) = evaluator.health(for: expiring, now: fixedNow, calendar: utcCalendar) else {
            Issue.record("Expected expiring for T-10d")
            return
        }
        #expect(days == 10)

        let healthy = connection(expiresInDays: 11)
        guard case .healthy = evaluator.health(for: healthy, now: fixedNow, calendar: utcCalendar) else {
            Issue.record("Expected healthy for T-11d")
            return
        }
    }

    @Test("Abgelaufener Consent ist expired")
    func expired() {
        let evaluator = ConnectionHealthEvaluator()
        let conn = connection(expiresInDays: -1)
        guard case .expired = evaluator.health(for: conn, now: fixedNow, calendar: utcCalendar) else {
            Issue.record("Expected expired")
            return
        }
    }

    @Test("Ohne Ablaufdatum: noConsentInfo")
    func noConsentInfo() {
        let evaluator = ConnectionHealthEvaluator()
        let conn = connection(status: .active, expiresInDays: nil, lastSyncDaysAgo: nil)
        #expect(evaluator.health(for: conn, now: fixedNow, calendar: utcCalendar) == .noConsentInfo)
    }

    @Test("Widerrufen/getrennt ist blockiert, auch bei gültigem Consent")
    func blockedDominates() {
        let evaluator = ConnectionHealthEvaluator()
        #expect(evaluator.health(for: connection(status: .revoked, expiresInDays: 30), now: fixedNow, calendar: utcCalendar) == .blocked)
        #expect(evaluator.health(for: connection(status: .disconnected, expiresInDays: 30), now: fixedNow, calendar: utcCalendar) == .blocked)
    }

    @Test("SCA ≤180d: 181 Tage ohne Sync ist expired, 175 Tage ist expiring")
    func scaWindow() {
        let evaluator = ConnectionHealthEvaluator()
        let stale = connection(status: .active, expiresInDays: nil, lastSyncDaysAgo: 181)
        guard case .expired = evaluator.health(for: stale, now: fixedNow, calendar: utcCalendar) else {
            Issue.record("Expected SCA-expired")
            return
        }
        let warning = connection(status: .active, expiresInDays: nil, lastSyncDaysAgo: 175)
        guard case .expiring(let days) = evaluator.health(for: warning, now: fixedNow, calendar: utcCalendar) else {
            Issue.record("Expected SCA-expiring")
            return
        }
        #expect(days == 5)
    }

    @Test("Banner-Quelle enthält nur expiring/expired (kein blocked, kein healthy)")
    func attentionFilter() {
        let evaluator = ConnectionHealthEvaluator()
        let list = [
            connection(expiresInDays: 5),
            connection(expiresInDays: -2),
            connection(expiresInDays: 30, lastSyncDaysAgo: 1),
            connection(status: .revoked, expiresInDays: 5),
        ]
        let attention = evaluator.connectionsNeedingAttention(in: list, now: fixedNow, calendar: utcCalendar)
        #expect(attention.count == 2)
        #expect(evaluator.bannerMessage(for: []) == nil)
        #expect(evaluator.bannerMessage(for: attention, now: fixedNow, calendar: utcCalendar) != nil)
    }

    @Test("3-Wege-Klassifikation: 401/403 = Re-Auth, 404/410 = blockiert, 5xx/429 = transient")
    func classifyThreeWays() {
        let evaluator = ConnectionHealthEvaluator()
        let conn = connection()
        #expect(evaluator.classify(syncError: BankProviderError.missingCredentials, connection: conn) == .reauthRequired)
        #expect(evaluator.classify(syncError: BankProviderError.requestFailed(endpoint: "x", status: 401, body: nil), connection: conn) == .reauthRequired)
        #expect(evaluator.classify(syncError: BankProviderError.requestFailed(endpoint: "x", status: 403, body: nil), connection: conn) == .reauthRequired)
        #expect(evaluator.classify(syncError: BankProviderError.requestFailed(endpoint: "x", status: 404, body: nil), connection: conn) == .blocked)
        #expect(evaluator.classify(syncError: BankProviderError.requestFailed(endpoint: "x", status: 410, body: nil), connection: conn) == .blocked)
        #expect(evaluator.classify(syncError: BankProviderError.requestFailed(endpoint: "x", status: 500, body: nil), connection: conn) == .transientRetry)
        #expect(evaluator.classify(syncError: BankProviderError.requestFailed(endpoint: "x", status: 429, body: nil), connection: conn) == .transientRetry)
        #expect(evaluator.classify(syncError: BankProviderError.invalidResponse(endpoint: "x"), connection: conn) == .transientRetry)
    }

    @Test("Nicht autorisierte Bankverbindung braucht Re-Auth; widerrufene ist blockiert")
    func classifyAuthorizationErrors() {
        let evaluator = ConnectionHealthEvaluator()
        let conn = connection()
        let pending = ImportError.unsupportedFormat(reason: "Die Bankverbindung ist noch nicht vollständig autorisiert.")
        #expect(evaluator.classify(syncError: pending, connection: conn) == .reauthRequired)
        let revoked = connection(status: .revoked)
        #expect(evaluator.classify(syncError: BankProviderError.requestFailed(endpoint: "x", status: 500, body: nil), connection: revoked) == .blocked)
    }
}
