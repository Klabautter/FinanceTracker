import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("BankSyncCoordinator")
struct BankSyncCoordinatorTests {
    /// Anbieter je Verbindung, damit eine Bank scheitern kann und die
    /// andere nicht.
    private struct PerConnectionFactory: BankProviderResolving {
        let providers: [String: any BankDataProvider]
        let fallback: any BankDataProvider

        func makeBankDataProvider() -> any BankDataProvider { fallback }
        func makeBankDataProvider(for connection: Connection) -> any BankDataProvider {
            connection.providerConnectionID.flatMap { providers[$0] } ?? fallback
        }
    }

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var statusCalls = 0
        private var running = 0
        private var maxRunning = 0

        var statusCallCount: Int { lock.withLock { statusCalls } }
        var maxConcurrent: Int { lock.withLock { maxRunning } }

        func enter() {
            lock.withLock {
                statusCalls += 1
                running += 1
                maxRunning = max(maxRunning, running)
            }
        }

        func leave() { lock.withLock { running -= 1 } }
    }

    private struct ThrowingProvider: BankDataProvider {
        let bankError: BankProviderError
        let log: CallLog
        var identifier: String = ConnectionProvider.gocardless.rawValue
        var displayName: String = "Test"
        func institutions(country: String) async throws -> [BankInstitution] { throw bankError }
        func createConnection(institutionID: String, redirectURL: URL?) async throws -> (connectionID: String, authorizationURL: URL?) { throw bankError }
        func connectionStatus(connectionID: String) async throws -> RemoteConnectionState {
            log.enter()
            defer { log.leave() }
            throw bankError
        }
        func fetchAccountData(accountID: String, dateFrom: Date?) async throws -> RemoteBankAccountData { throw bankError }
        func authorizeSession(code: String) async throws -> String { throw bankError }
    }

    private struct OfflineProvider: BankDataProvider {
        let log: CallLog
        var identifier: String = ConnectionProvider.gocardless.rawValue
        var displayName: String = "Offline"
        func institutions(country: String) async throws -> [BankInstitution] { [] }
        func createConnection(institutionID: String, redirectURL: URL?) async throws -> (connectionID: String, authorizationURL: URL?) { ("x", nil) }
        func connectionStatus(connectionID: String) async throws -> RemoteConnectionState {
            log.enter()
            defer { log.leave() }
            throw URLError(.notConnectedToInternet)
        }
        func fetchAccountData(accountID: String, dateFrom: Date?) async throws -> RemoteBankAccountData {
            throw URLError(.notConnectedToInternet)
        }
        func authorizeSession(code: String) async throws -> String { "x" }
    }

    /// Scheitert auf Wunsch mit 503, sonst leerer, erfolgreicher Abruf.
    private final class SwitchableProvider: BankDataProvider, @unchecked Sendable {
        let log: CallLog
        var fails = false
        let identifier: String = ConnectionProvider.gocardless.rawValue
        let displayName: String = "Schaltbar"
        init(log: CallLog) { self.log = log }
        func institutions(country: String) async throws -> [BankInstitution] { [] }
        func createConnection(institutionID: String, redirectURL: URL?) async throws -> (connectionID: String, authorizationURL: URL?) { ("x", nil) }
        func connectionStatus(connectionID: String) async throws -> RemoteConnectionState {
            if fails { throw BankProviderError.requestFailed(endpoint: "sync", status: 503, body: nil) }
            return RemoteConnectionState(linkedAccountIDs: [], authorization: .ready)
        }
        func fetchAccountData(accountID: String, dateFrom: Date?) async throws -> RemoteBankAccountData {
            throw BankProviderError.invalidResponse(endpoint: "accounts")
        }
        func authorizeSession(code: String) async throws -> String { "x" }
    }

    /// Bleibt kurz im Abruf stehen, damit sich überlappende Abrufe zeigen.
    private struct SlowProvider: BankDataProvider {
        let log: CallLog
        var identifier: String = ConnectionProvider.gocardless.rawValue
        var displayName: String = "Langsam"
        func institutions(country: String) async throws -> [BankInstitution] { [] }
        func createConnection(institutionID: String, redirectURL: URL?) async throws -> (connectionID: String, authorizationURL: URL?) { ("x", nil) }
        func connectionStatus(connectionID: String) async throws -> RemoteConnectionState {
            log.enter()
            defer { log.leave() }
            try await Task.sleep(for: .milliseconds(40))
            return RemoteConnectionState(linkedAccountIDs: [], authorization: .ready)
        }
        func fetchAccountData(accountID: String, dateFrom: Date?) async throws -> RemoteBankAccountData {
            throw BankProviderError.invalidResponse(endpoint: "accounts")
        }
        func authorizeSession(code: String) async throws -> String { "x" }
    }

    private func mockProvider(accountID: String, transactionIDs: [String]) -> MockBankDataProvider {
        let provider = MockBankDataProvider()
        provider.stubbedLinkedAccountIDs = [accountID]
        provider.stubbedRemoteAccounts = [RemoteBankAccount(
            id: accountID,
            providerAccountID: accountID,
            ownerName: "Test User",
            maskedIBAN: "•••• \(accountID.suffix(4))",
            currency: .eur
        )]
        provider.stubbedTransactions = transactionIDs.map {
            RemoteBankTransaction(
                externalID: $0,
                state: .booked,
                amount: Money(amount: Decimal(string: "-12.50")!, currency: .eur),
                bookingDate: Date(timeIntervalSince1970: 1_770_000_000),
                valueDate: nil,
                creditorName: "REWE MARKT",
                debtorName: nil,
                remittanceInformation: "Einkauf \($0)"
            )
        }
        return provider
    }

    private func makeDependencies(
        providers: [String: any BankDataProvider],
        automaticBankSyncEnabled: Bool = true
    ) throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(
            container: store.container,
            baseCurrency: .eur,
            bankProviderFactory: PerConnectionFactory(providers: providers, fallback: MockBankDataProvider()),
            preferences: InMemoryAppPreferences(automaticBankSyncEnabled: automaticBankSyncEnabled)
        )
    }

    private func connection(
        session: String,
        name: String,
        status: ConnectionStatus = .active,
        consentExpiresInDays: Int = 30,
        lastSyncHoursAgo: Double? = nil,
        createdOffset: TimeInterval = 0
    ) -> Connection {
        let now = Date()
        return Connection(
            id: UUID(),
            userID: UUID(),
            provider: .gocardless,
            providerConnectionID: session,
            institutionID: "inst-\(session)",
            status: status,
            consentExpiresAt: Calendar.current.date(byAdding: .day, value: consentExpiresInDays, to: now),
            lastSuccessfulSyncAt: lastSyncHoursAgo.map { now.addingTimeInterval(-$0 * 3_600) },
            createdAt: now.addingTimeInterval(createdOffset),
            updatedAt: now,
            institutionName: name
        )
    }

    @Test("Automatik ruft fällige Banken ab und lässt frische in Ruhe")
    func automaticSyncsOnlyDueConnections() async throws {
        let due = mockProvider(accountID: "acc-due-0001", transactionIDs: ["D1", "D2"])
        let fresh = mockProvider(accountID: "acc-fresh-0002", transactionIDs: ["F1"])
        let dependencies = try makeDependencies(providers: ["due": due, "fresh": fresh])
        try await dependencies.connectionRepository.upsert([
            connection(session: "due", name: "Alte Bank", lastSyncHoursAgo: 7),
            connection(session: "fresh", name: "Frische Bank", lastSyncHoursAgo: 1, createdOffset: 1)
        ])
        let coordinator = dependencies.bankSyncCoordinator

        let summary = try #require(await coordinator.syncAll(trigger: .automatic, dependencies: dependencies))

        #expect(summary.syncedConnectionCount == 1)
        #expect(summary.importedCount == 2)
        #expect(!summary.hasProblems)
        #expect(due.fetchAccountDataCallCount == 1)
        #expect(fresh.fetchAccountDataCallCount == 0)
        #expect(try await dependencies.transactionRepository.count() == 2)
        // Ein stiller, erfolgreicher Automatik-Lauf meldet nichts.
        #expect(coordinator.lastSummary == nil)
        #expect(!coordinator.isSyncingAll)
        #expect(coordinator.syncingConnectionIDs.isEmpty)

        // Direkt danach ist nichts mehr fällig; die letzte Meldung bleibt.
        let second = try #require(await coordinator.syncAll(trigger: .automatic, dependencies: dependencies))
        #expect(second.syncedConnectionCount == 0)
        #expect(due.fetchAccountDataCallCount == 1)
        #expect(coordinator.lastSummary == nil)
    }

    @Test("„Alle aktualisieren“ ruft jede Bank ab, auch kurz nach dem letzten Abruf")
    func manualIgnoresInterval() async throws {
        let first = mockProvider(accountID: "acc-a-0001", transactionIDs: ["A1"])
        let second = mockProvider(accountID: "acc-b-0002", transactionIDs: ["B1", "B2"])
        let dependencies = try makeDependencies(providers: ["a": first, "b": second])
        try await dependencies.connectionRepository.upsert([
            connection(session: "a", name: "Bank A", lastSyncHoursAgo: 0.1),
            connection(session: "b", name: "Bank B", lastSyncHoursAgo: 0.1, createdOffset: 1)
        ])

        let summary = try #require(await dependencies.bankSyncCoordinator.syncAll(trigger: .manual, dependencies: dependencies))

        #expect(summary.syncedConnectionCount == 2)
        #expect(summary.importedCount == 3)
        #expect(first.fetchAccountDataCallCount == 1)
        #expect(second.fetchAccountDataCallCount == 1)
        #expect(summary.message.contains("2 Banken aktualisiert"))
    }

    @Test("Ausgeschaltete Automatik ruft nichts ab, der Klick geht weiter")
    func disabledPreferenceStopsAutomaticOnly() async throws {
        let provider = mockProvider(accountID: "acc-a-0001", transactionIDs: ["A1"])
        let dependencies = try makeDependencies(providers: ["a": provider], automaticBankSyncEnabled: false)
        try await dependencies.connectionRepository.upsert([connection(session: "a", name: "Bank A")])
        let coordinator = dependencies.bankSyncCoordinator

        #expect(await coordinator.syncAll(trigger: .automatic, dependencies: dependencies) == nil)
        #expect(provider.fetchAccountDataCallCount == 0)
        #expect(coordinator.lastSummary == nil)

        let manual = try #require(await coordinator.syncAll(trigger: .manual, dependencies: dependencies))
        #expect(manual.syncedConnectionCount == 1)
        #expect(provider.fetchAccountDataCallCount == 1)
    }

    @Test("Abgelaufene Zustimmung wird übersprungen und gemeldet")
    func expiredConsentIsSkippedAndReported() async throws {
        let provider = mockProvider(accountID: "acc-a-0001", transactionIDs: ["A1"])
        let dependencies = try makeDependencies(providers: ["a": provider])
        try await dependencies.connectionRepository.upsert([
            connection(session: "a", name: "Alte Sparkasse", consentExpiresInDays: -2)
        ])

        let summary = try #require(await dependencies.bankSyncCoordinator.syncAll(trigger: .automatic, dependencies: dependencies))

        #expect(provider.fetchAccountDataCallCount == 0)
        #expect(summary.reauthorizations.map(\.connectionName) == ["Alte Sparkasse"])
        #expect(summary.hasProblems)
        #expect(summary.message.contains("Alte Sparkasse"))
        #expect(summary.message.contains("erneuern"))
        let coordinator = dependencies.bankSyncCoordinator
        #expect(coordinator.lastSummary == summary)

        // Geschlossen bleibt geschlossen: Derselbe Hinweis kommt nicht bei
        // jedem automatischen Lauf wieder.
        coordinator.dismissSummary()
        await coordinator.syncAll(trigger: .automatic, dependencies: dependencies)
        #expect(coordinator.lastSummary == nil)
    }

    @Test("Eine gestörte Bank hält die anderen nicht auf und wird nicht sofort erneut versucht")
    func failureIsReportedAndBacksOff() async throws {
        let log = CallLog()
        let failing = ThrowingProvider(
            bankError: .requestFailed(endpoint: "sync", status: 503, body: nil),
            log: log
        )
        let healthy = mockProvider(accountID: "acc-ok-0001", transactionIDs: ["O1"])
        let dependencies = try makeDependencies(providers: ["bad": failing, "ok": healthy])
        let bad = connection(session: "bad", name: "Störbank")
        try await dependencies.connectionRepository.upsert([
            bad,
            connection(session: "ok", name: "Gute Bank", createdOffset: 1)
        ])
        let coordinator = dependencies.bankSyncCoordinator

        let summary = try #require(await coordinator.syncAll(trigger: .automatic, dependencies: dependencies))

        #expect(summary.syncedConnectionCount == 1)
        #expect(summary.failures == [.init(connectionID: bad.id, connectionName: "Störbank", kind: .transientRetry)])
        #expect(summary.message.contains("Störbank"))
        #expect(log.statusCallCount == 1)
        #expect(healthy.fetchAccountDataCallCount == 1)

        // Automatik wartet nach dem Fehlversuch; der Klick versucht es erneut.
        await coordinator.syncAll(trigger: .automatic, dependencies: dependencies)
        #expect(log.statusCallCount == 1)
        await coordinator.syncAll(trigger: .manual, dependencies: dependencies)
        #expect(log.statusCallCount == 2)

        // Nach dem zweiten Fehlversuch gilt der volle Abstand: auch eine
        // Stunde später noch kein automatischer Versuch.
        let inTwoHours = Date().addingTimeInterval(2 * 3_600)
        await coordinator.syncAll(trigger: .automatic, dependencies: dependencies, now: inTwoHours)
        #expect(log.statusCallCount == 2)
    }

    @Test("Vom Server abgelehnt: Automatik fragt nicht erneut an, erinnert aber")
    func rejectedConnectionIsNotRetriedAutomatically() async throws {
        let log = CallLog()
        let failing = ThrowingProvider(
            bankError: .requestFailed(endpoint: "sync", status: 401, body: nil),
            log: log
        )
        let dependencies = try makeDependencies(providers: ["bad": failing])
        try await dependencies.connectionRepository.upsert([connection(session: "bad", name: "Volksbank")])
        let coordinator = dependencies.bankSyncCoordinator

        await coordinator.syncAll(trigger: .automatic, dependencies: dependencies)
        #expect(log.statusCallCount == 1)

        let tomorrow = Date().addingTimeInterval(86_400)
        let later = try #require(await coordinator.syncAll(trigger: .automatic, dependencies: dependencies, now: tomorrow))
        #expect(log.statusCallCount == 1)
        #expect(later.reauthorizations.map(\.connectionName) == ["Volksbank"])
    }

    @Test("Ohne Netz meldet die Automatik nichts und versucht es bald wieder")
    func offlineIsSilentForAutomaticRuns() async throws {
        let log = CallLog()
        let dependencies = try makeDependencies(providers: ["a": OfflineProvider(log: log)])
        try await dependencies.connectionRepository.upsert([connection(session: "a", name: "Bank A")])
        let coordinator = dependencies.bankSyncCoordinator

        let summary = try #require(await coordinator.syncAll(trigger: .automatic, dependencies: dependencies))
        #expect(!summary.hasProblems)
        #expect(coordinator.lastSummary == nil)
        #expect(log.statusCallCount == 1)

        // Fünf Minuten später noch nicht, nach einer Viertelstunde wieder.
        await coordinator.syncAll(trigger: .automatic, dependencies: dependencies, now: Date().addingTimeInterval(300))
        #expect(log.statusCallCount == 1)
        await coordinator.syncAll(trigger: .automatic, dependencies: dependencies, now: Date().addingTimeInterval(900))
        #expect(log.statusCallCount == 2)

        // Der Klick meldet den Fehlschlag.
        let manual = try #require(await coordinator.syncAll(trigger: .manual, dependencies: dependencies))
        #expect(manual.failures.map(\.kind) == [.transientRetry])
    }

    @Test("Problemmeldung verschwindet, sobald die Bank wieder abrufbar ist")
    func problemNoticeClearsAfterSuccess() async throws {
        let provider = SwitchableProvider(log: CallLog())
        let dependencies = try makeDependencies(providers: ["a": provider])
        let stored = connection(session: "a", name: "Bank A")
        try await dependencies.connectionRepository.upsert([stored])
        let coordinator = dependencies.bankSyncCoordinator

        provider.fails = true
        await coordinator.syncAll(trigger: .manual, dependencies: dependencies)
        #expect(coordinator.lastSummary?.hasProblems == true)

        provider.fails = false
        _ = try await coordinator.sync(stored, dependencies: dependencies)
        #expect(coordinator.lastSummary == nil)
    }

    @Test("Getrennte Verbindung wird nicht abgerufen und nicht wieder angelegt")
    func removedConnectionIsNotResurrected() async throws {
        let provider = mockProvider(accountID: "acc-a-0001", transactionIDs: ["A1"])
        let dependencies = try makeDependencies(providers: ["a": provider])
        let stored = connection(session: "a", name: "Bank A")
        try await dependencies.connectionRepository.upsert([stored])
        try await dependencies.connectionRepository.delete(id: stored.id)

        await #expect(throws: BankSyncCoordinatorError.self) {
            _ = try await dependencies.bankSyncCoordinator.sync(stored, dependencies: dependencies)
        }
        #expect(provider.fetchAccountDataCallCount == 0)
        #expect(try await dependencies.connectionRepository.connections().isEmpty)

        // Auch ein Abruf, der die Verbindung noch kannte, legt sie am Ende
        // nicht wieder an.
        _ = try await BankSyncService(dependencies: dependencies, provider: provider).sync(connection: stored)
        #expect(try await dependencies.connectionRepository.connections().isEmpty)
    }

    @Test("Abgebrochener Lauf zählt nicht als Fehlversuch der Bank")
    func cancellationIsNotAFailure() {
        #expect(BankSyncCoordinator.attemptFailure(for: CancellationError(), kind: .transientRetry) == nil)
        #expect(BankSyncCoordinator.attemptFailure(for: URLError(.cancelled), kind: .transientRetry) == nil)
        #expect(BankSyncCoordinator.attemptFailure(for: URLError(.notConnectedToInternet), kind: .transientRetry) == .offline)
        #expect(BankSyncCoordinator.attemptFailure(for: URLError(.badServerResponse), kind: .transientRetry) == .transient)
        #expect(BankSyncCoordinator.attemptFailure(for: BankProviderError.missingCredentials, kind: .reauthRequired) == .needsUserAction)
    }

    @Test("401 beim Abruf landet bei „Zugang erneuern“")
    func reauthFailureIsListedForRenewal() async throws {
        let failing = ThrowingProvider(
            bankError: .requestFailed(endpoint: "sync", status: 401, body: nil),
            log: CallLog()
        )
        let dependencies = try makeDependencies(providers: ["bad": failing])
        try await dependencies.connectionRepository.upsert([connection(session: "bad", name: "Volksbank")])

        let summary = try #require(await dependencies.bankSyncCoordinator.syncAll(trigger: .manual, dependencies: dependencies))

        #expect(summary.failures.map(\.kind) == [.reauthRequired])
        #expect(summary.message.contains("Zugang erneuern: Volksbank"))
    }

    @Test("Einzelabruf und Sammelabruf laufen nie gleichzeitig")
    func syncsAreSerialized() async throws {
        let log = CallLog()
        let slow = SlowProvider(log: log)
        let dependencies = try makeDependencies(providers: ["a": slow, "b": slow])
        let first = connection(session: "a", name: "Bank A")
        let second = connection(session: "b", name: "Bank B", createdOffset: 1)
        try await dependencies.connectionRepository.upsert([first, second])
        let coordinator = dependencies.bankSyncCoordinator

        async let all = coordinator.syncAll(trigger: .manual, dependencies: dependencies)
        async let single = coordinator.sync(second, dependencies: dependencies)
        _ = await all
        _ = try await single

        #expect(log.statusCallCount == 3)
        #expect(log.maxConcurrent == 1)
        #expect(coordinator.syncingConnectionIDs.isEmpty)
    }

    @Test("Ein laufender Sammelabruf startet keinen zweiten")
    func secondRunWhileRunningIsSkipped() async throws {
        let log = CallLog()
        let dependencies = try makeDependencies(providers: ["a": SlowProvider(log: log)])
        try await dependencies.connectionRepository.upsert([connection(session: "a", name: "Bank A")])
        let coordinator = dependencies.bankSyncCoordinator

        async let first = coordinator.syncAll(trigger: .manual, dependencies: dependencies)
        async let second = coordinator.syncAll(trigger: .manual, dependencies: dependencies)
        let results = await [first, second]

        #expect(results.compactMap { $0 }.count == 1)
        #expect(log.statusCallCount == 1)
    }

    @Test("Der Knopf zählt nur Verbindungen, die sich abrufen lassen")
    func availabilityCountsSyncableConnections() async throws {
        let dependencies = try makeDependencies(providers: [:])
        var local = connection(session: "local", name: "Lokal", createdOffset: 2)
        local.provider = .local
        try await dependencies.connectionRepository.upsert([
            connection(session: "a", name: "Bank A"),
            connection(session: "gone", name: "Getrennt", status: .disconnected, createdOffset: 1),
            local
        ])
        let coordinator = dependencies.bankSyncCoordinator
        #expect(coordinator.syncableConnectionCount == 0)

        await coordinator.refreshAvailability(dependencies: dependencies)

        #expect(coordinator.syncableConnectionCount == 1)
    }

    @Test("Klick ohne Bankverbindung meldet das, statt still nichts zu tun")
    func manualWithoutConnections() async throws {
        let dependencies = try makeDependencies(providers: [:])

        let summary = try #require(await dependencies.bankSyncCoordinator.syncAll(trigger: .manual, dependencies: dependencies))

        #expect(summary.syncedConnectionCount == 0)
        #expect(summary.message == "Keine Bankverbindung zum Aktualisieren.")
        #expect(dependencies.bankSyncCoordinator.lastSummary == summary)
        dependencies.bankSyncCoordinator.dismissSummary()
        #expect(dependencies.bankSyncCoordinator.lastSummary == nil)
    }

    @Test("Einstellung: ohne gespeicherten Wert an, Änderung bleibt erhalten")
    func preferenceDefaultsToOnAndPersists() throws {
        let suite = "BankSyncCoordinatorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = UserDefaultsAppPreferences(defaults: defaults)
        #expect(preferences.automaticBankSyncEnabled)
        preferences.setAutomaticBankSyncEnabled(false)
        #expect(!UserDefaultsAppPreferences(defaults: defaults).automaticBankSyncEnabled)
    }

    @Test("Test- und Demo-Starts rufen nie von selbst Bankdaten ab")
    func testLaunchesNeverSyncAutomatically() {
        #expect(AppLaunchEnvironment(arguments: [], configuration: .release).allowsAutomaticBankSync)
        #expect(AppLaunchEnvironment(arguments: [], configuration: .debug).allowsAutomaticBankSync)
        for arguments in [["-ui-testing"], ["-ui-testing-privacy-off"], ["-ui-testing-empty"],
                          ["-ui-testing-window", "1440x900"], ["-screenshot-demo"]] {
            let environment = AppLaunchEnvironment(arguments: arguments, configuration: .debug)
            #expect(!environment.allowsAutomaticBankSync, "\(arguments)")
        }
    }
}
