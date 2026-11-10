import Foundation
import Testing

@testable import FinanceTracker

@Suite("BankSyncPolicy")
struct BankSyncPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let policy = BankSyncPolicy()

    private func connection(
        provider: ConnectionProvider = .enablebanking,
        providerConnectionID: String? = "session-1",
        status: ConnectionStatus = .active,
        consentExpiresIn: TimeInterval? = 30 * 86_400,
        lastSyncAgo: TimeInterval? = nil
    ) -> Connection {
        Connection(
            id: UUID(),
            userID: UUID(),
            provider: provider,
            providerConnectionID: providerConnectionID,
            institutionID: "inst-1",
            status: status,
            consentExpiresAt: consentExpiresIn.map { now.addingTimeInterval($0) },
            lastSuccessfulSyncAt: lastSyncAgo.map { now.addingTimeInterval(-$0) },
            createdAt: now,
            updatedAt: now
        )
    }

    @Test("Ohne Online-Anbieter oder Sitzung gibt es nichts abzurufen", arguments: [
        ConnectionProvider.local, .mock, .future, .tink
    ])
    func offlineProvidersAreNotSyncable(provider: ConnectionProvider) {
        #expect(policy.decision(for: connection(provider: provider), trigger: .manual, now: now) == .notSyncable)
    }

    @Test("Verbindung ohne Sitzungskennung wird nicht abgerufen")
    func missingSessionIsNotSyncable() {
        #expect(policy.decision(for: connection(providerConnectionID: nil), trigger: .manual, now: now) == .notSyncable)
    }

    @Test("Getrennt und offene Freigabe: kein Abruf, keine Mahnung")
    func disconnectedAndPendingAreNotSyncable() {
        for status in [ConnectionStatus.disconnected, .pendingAuthorization] {
            #expect(policy.decision(for: connection(status: status), trigger: .manual, now: now) == .notSyncable)
            #expect(policy.decision(for: connection(status: status), trigger: .automatic, now: now) == .notSyncable)
        }
    }

    @Test("Abgelaufen oder widerrufen: erst neu freigeben, auch beim Klick")
    func expiredNeedsReauthorization() {
        for status in [ConnectionStatus.expired, .revoked] {
            #expect(policy.decision(for: connection(status: status), trigger: .manual, now: now) == .needsReauthorization)
        }
        let consentOver = connection(consentExpiresIn: -60)
        #expect(policy.decision(for: consentOver, trigger: .automatic, now: now) == .needsReauthorization)
        #expect(policy.decision(for: consentOver, trigger: .manual, now: now) == .needsReauthorization)
    }

    @Test("Automatik hält sechs Stunden Abstand, ein Klick gilt immer")
    func automaticRespectsMinimumInterval() {
        let never = connection(lastSyncAgo: nil)
        let fresh = connection(lastSyncAgo: 5 * 3_600)
        let due = connection(lastSyncAgo: 6 * 3_600)
        #expect(policy.decision(for: never, trigger: .automatic, now: now) == .sync)
        #expect(policy.decision(for: fresh, trigger: .automatic, now: now) == .notDue)
        #expect(policy.decision(for: due, trigger: .automatic, now: now) == .sync)
        #expect(policy.decision(for: connection(lastSyncAgo: 60), trigger: .manual, now: now) == .sync)
    }

    @Test("Nach einem Fehlversuch wartet die Automatik, der Klick nicht")
    func automaticWaitsUntilNotBefore() {
        let due = connection(lastSyncAgo: 10 * 3_600)
        let later = now.addingTimeInterval(600)
        let earlier = now.addingTimeInterval(-60)
        #expect(policy.decision(for: due, trigger: .automatic, automaticNotBefore: later, now: now) == .notDue)
        #expect(policy.decision(for: due, trigger: .manual, automaticNotBefore: later, now: now) == .sync)
        #expect(policy.decision(for: due, trigger: .automatic, automaticNotBefore: earlier, now: now) == .sync)
    }

    @Test("Wartezeit: offline kurz, erste Störung eine Stunde, danach sechs, ohne Zugang nie")
    func retryDelayEscalates() {
        #expect(policy.automaticRetryDelay(after: .offline, consecutiveFailures: 5) == 600)
        #expect(policy.automaticRetryDelay(after: .transient, consecutiveFailures: 1) == 3_600)
        #expect(policy.automaticRetryDelay(after: .transient, consecutiveFailures: 2) == 21_600)
        #expect(policy.automaticRetryDelay(after: .transient, consecutiveFailures: 9) == 21_600)
        #expect(policy.automaticRetryDelay(after: .needsUserAction, consecutiveFailures: 1) == nil)
    }

    @Test("Ein Abrufzeitpunkt in der Zukunft löst keinen Dauerabruf aus")
    func futureLastSyncIsNotDue() {
        #expect(policy.decision(for: connection(lastSyncAgo: -3_600), trigger: .automatic, now: now) == .notDue)
    }
}
