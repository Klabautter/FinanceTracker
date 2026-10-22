import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("ConnectionHealthModel")
struct ConnectionHealthTests {
    private struct StaticFactory: BankProviderResolving {
        let provider: any BankDataProvider
        func makeBankDataProvider() -> any BankDataProvider { provider }
    }

    private struct ThrowingProvider: BankDataProvider {
        let bankError: BankProviderError
        var identifier: String = "test-throwing"
        var displayName: String = "Test"
        func institutions(country: String) async throws -> [BankInstitution] { throw bankError }
        func createConnection(institutionID: String, redirectURL: URL?) async throws -> (connectionID: String, authorizationURL: URL?) { throw bankError }
        func connectionStatus(connectionID: String) async throws -> RemoteConnectionState { throw bankError }
        func fetchAccountData(accountID: String, dateFrom: Date?) async throws -> RemoteBankAccountData { throw bankError }
        func authorizeSession(code: String) async throws -> String { throw bankError }
    }

    private func makeDependencies(provider: (any BankDataProvider)? = nil, bankError: BankProviderError? = nil) throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        if let bankError {
            return AppDependencies.make(
                container: store.container,
                baseCurrency: .eur,
                bankProviderFactory: StaticFactory(provider: ThrowingProvider(bankError: bankError))
            )
        }
        if let provider {
            return AppDependencies.make(
                container: store.container,
                baseCurrency: .eur,
                bankProviderFactory: StaticFactory(provider: provider)
            )
        }
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func makeModel(dependencies: AppDependencies) -> BankConnectModel {
        BankConnectModel(
            kind: .enablebanking,
            dependencies: dependencies,
            credentialStore: InMemoryGoCardlessCredentialStore(),
            enableBankingCredentialStore: InMemoryEnableBankingCredentialStore(applicationID: nil, privateKeyPEM: nil),
            providerFactory: StaticFactory(provider: MockBankDataProvider())
        )
    }

    private func storedConnection(expiresInDays: Int?) -> Connection {
        let now = Date()
        return Connection(
            id: UUID(),
            userID: UUID(),
            provider: .enablebanking,
            providerConnectionID: "provider-1",
            institutionID: "inst-1",
            status: .active,
            consentExpiresAt: expiresInDays.map { Calendar.current.date(byAdding: .day, value: $0, to: now)! },
            lastSuccessfulSyncAt: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    @Test("Banner erscheint bei T-10d, nicht bei gesundem Zugang")
    func bannerThreshold() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.connectionRepository.upsert([storedConnection(expiresInDays: 5)])
        let model = makeModel(dependencies: dependencies)
        await model.loadConnections()
        #expect(model.connections.count == 1)
        #expect(model.showsConsentBanner)
        #expect(model.consentBannerMessage != nil)

        try await dependencies.connectionRepository.deleteAll()
        try await dependencies.connectionRepository.upsert([storedConnection(expiresInDays: 30)])
        await model.loadConnections()
        #expect(!model.showsConsentBanner)
        #expect(model.consentBannerMessage == nil)
    }

    @Test("3-Wege-Texte sind unterscheidbar (retry vs. erneuern vs. neu verbinden)")
    func threeWayMessages() {
        let retry = BankConnectModel.syncDisplayMessage(
            kind: .transientRetry,
            error: BankProviderError.requestFailed(endpoint: "x", status: 500, body: nil)
        )
        let reauth = BankConnectModel.syncDisplayMessage(kind: .reauthRequired, error: BankProviderError.missingCredentials)
        let blocked = BankConnectModel.syncDisplayMessage(
            kind: .blocked,
            error: BankProviderError.requestFailed(endpoint: "x", status: 404, body: nil)
        )
        #expect(retry.contains("erneut versuchen"))
        #expect(reauth.contains("erneuern"))
        #expect(blocked.contains("neu verbinden"))
    }

    @Test("Refresh mit 401 speichert Re-Auth, mit 404 blockiert, mit 500 transient")
    func refreshClassifies() async throws {
        for (status, expected): (Int, SyncFailureKind) in [(401, .reauthRequired), (404, .blocked), (500, .transientRetry)] {
            let dependencies = try makeDependencies(bankError: .requestFailed(endpoint: "sync", status: status, body: nil))
            let stored = storedConnection(expiresInDays: 30)
            try await dependencies.connectionRepository.upsert([stored])
            let model = makeModel(dependencies: dependencies)
            await model.loadConnections()
            let connection = try #require(model.connections.first)
            await model.refreshConnection(connection)
            #expect(model.syncIssue(for: connection) == expected, "HTTP \(status) sollte \(expected) sein")
            #expect(model.syncIssueMessage(for: connection) != nil)
        }
    }

    @Test("Abgelaufener Consent meldet Re-Connect-Status")
    func expiredStatusLabel() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.connectionRepository.upsert([storedConnection(expiresInDays: -1)])
        let model = makeModel(dependencies: dependencies)
        await model.loadConnections()
        let connection = try #require(model.connections.first)
        #expect(model.statusLabel(for: connection) == "Zustimmung abgelaufen")
        #expect(model.needsReconnect(connection))
    }
}
