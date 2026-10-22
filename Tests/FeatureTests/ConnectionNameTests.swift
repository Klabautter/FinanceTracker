import Foundation
import Testing

@testable import FinanceTracker

/// Bankverbindungen heißen nach der Bank, nicht nach dem Anbieter.
@MainActor
@Suite("ConnectionName")
struct ConnectionNameTests {
    private struct NamingProvider: BankDataProvider {
        var identifier: String { "enablebanking" }
        var displayName: String { "Enable Banking" }
        func institutions(country: String) async throws -> [BankInstitution] { [] }
        func createConnection(institutionID: String, redirectURL: URL?) async throws -> (connectionID: String, authorizationURL: URL?) {
            throw BankProviderError.missingCredentials
        }
        func connectionStatus(connectionID: String) async throws -> RemoteConnectionState {
            throw BankProviderError.missingCredentials
        }
        func fetchAccountData(accountID: String, dateFrom: Date?) async throws -> RemoteBankAccountData {
            throw BankProviderError.missingCredentials
        }
        func authorizeSession(code: String) async throws -> String { throw BankProviderError.missingCredentials }
        func institutionDisplayName(forInstitutionID institutionID: String) -> String? {
            institutionID.split(separator: "|", maxSplits: 1).last.map(String.init)
        }
    }

    private struct NamingFactory: BankProviderResolving {
        func makeBankDataProvider() -> any BankDataProvider { NamingProvider() }
    }

    private func connection(name: String? = nil) -> Connection {
        Connection(
            id: UUID(),
            userID: UUID(),
            provider: .enablebanking,
            providerConnectionID: "session",
            institutionID: "DE|VR Bank Beispiel",
            status: .active,
            consentExpiresAt: nil,
            lastSuccessfulSyncAt: nil,
            createdAt: Date(),
            updatedAt: Date(),
            institutionName: name
        )
    }

    @Test("Anzeigename ist die Bank, sonst der Anbieter")
    func displayName() {
        #expect(connection(name: "VR Bank Beispiel").displayName == "VR Bank Beispiel")
        #expect(connection().displayName == "Enable Banking")
        #expect(connection(name: "").displayName == "Enable Banking")
    }

    @Test("Der Bankname wird gespeichert und wieder gelesen")
    func persistsInstitutionName() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let stored = connection(name: "VR Bank Beispiel")
        try await dependencies.connectionRepository.upsert([stored])

        let read = try await dependencies.connectionRepository.connections()
        #expect(read.first?.institutionName == "VR Bank Beispiel")
    }

    @Test("Bestehende Verbindungen ohne Namen bekommen ihn beim Laden der Konten, ohne Bankabruf")
    func backfillsNameOnLoad() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(
            container: store.container,
            baseCurrency: .eur,
            bankProviderFactory: NamingFactory()
        )
        try await dependencies.connectionRepository.upsert([connection()])

        let model = AccountsModel(dependencies: dependencies)
        await model.load()

        #expect(model.connections.first?.displayName == "VR Bank Beispiel")
        let read = try await dependencies.connectionRepository.connections()
        #expect(read.first?.institutionName == "VR Bank Beispiel")
    }
}

@Suite("BankProviderExistentialRouting")
struct BankProviderExistentialRoutingTests {
    @Test("Routing greift auch über den Protokolltyp: Enable-Banking-Verbindungen gehen an Enable Banking")
    func routesThroughExistential() {
        let factory: any BankProviderResolving = RoutedBankProviderFactory(
            enableBanking: EnableBankingProviderFactory(
                redirectURL: EnableBankingProviderFactory.defaultRedirectURL,
                credentialStore: InMemoryEnableBankingCredentialStore(applicationID: nil, privateKeyPEM: nil)
            ),
            goCardless: GoCardlessPoCProviderFactory(credentialStore: InMemoryGoCardlessCredentialStore())
        )
        let connection = Connection(
            id: UUID(), userID: UUID(), provider: .enablebanking, providerConnectionID: "s",
            institutionID: "DE|VR Bank Beispiel", status: .active, consentExpiresAt: nil,
            lastSuccessfulSyncAt: nil, createdAt: Date(), updatedAt: Date()
        )
        let provider = factory.makeBankDataProvider(for: connection)
        #expect(provider.identifier == ConnectionProvider.enablebanking.rawValue)
        #expect(provider.institutionDisplayName(forInstitutionID: "DE|VR Bank Beispiel") == "VR Bank Beispiel")
    }
}
