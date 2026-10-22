import Foundation
import Testing

@testable import FinanceTracker

/// WP-MacUX: Der Sync einer Enable-Banking-Connection darf nicht gegen
/// die GoCardless-API laufen („BankProviderError-Fehler 2" = HTTP-Fehler).
/// Das Routing wählt den Provider anhand Connection.provider.
@MainActor
@Suite("BankProviderRouting")
struct BankProviderRoutingTests {
    private func makeConnection(provider: ConnectionProvider) -> Connection {
        Connection(
            id: UUID(),
            userID: UUID(),
            provider: provider,
            providerConnectionID: "session-1",
            institutionID: "SANDBOXFINANCE_SFIN000033",
            status: .active,
            consentExpiresAt: nil,
            lastSuccessfulSyncAt: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    @Test("Enable-Banking-Connection erhält den Enable-Banking-Provider")
    func enableBankingConnectionRoutesToEnableBankingProvider() {
        let factory = RoutedBankProviderFactory(
            enableBanking: EnableBankingProviderFactory(
                redirectURL: EnableBankingProviderFactory.defaultRedirectURL,
                credentialStore: InMemoryEnableBankingCredentialStore(
                    applicationID: "app-id",
                    privateKeyPEM: "key"
                )
            ),
            goCardless: GoCardlessPoCProviderFactory(
                credentialStore: InMemoryGoCardlessCredentialStore()
            )
        )

        let provider = factory.makeBankDataProvider(for: makeConnection(provider: .enablebanking))
        #expect(provider.identifier == ConnectionProvider.enablebanking.rawValue)
    }

    @Test("GoCardless-Connection erhält den GoCardless-Provider")
    func goCardlessConnectionRoutesToGoCardlessProvider() {
        let factory = RoutedBankProviderFactory(
            enableBanking: EnableBankingProviderFactory(
                redirectURL: EnableBankingProviderFactory.defaultRedirectURL,
                credentialStore: InMemoryEnableBankingCredentialStore(
                    applicationID: "app-id",
                    privateKeyPEM: "key"
                )
            ),
            goCardless: GoCardlessPoCProviderFactory(
                credentialStore: InMemoryGoCardlessCredentialStore()
            )
        )

        let provider = factory.makeBankDataProvider(for: makeConnection(provider: .gocardless))
        #expect(provider.identifier == ConnectionProvider.gocardless.rawValue)
    }

    @Test("Legacy-Einstieg ohne Connection bleibt provider-agnostisch (GoCardless-PoC)")
    func legacyEntryWithoutConnection() {
        let factory = RoutedBankProviderFactory(
            enableBanking: EnableBankingProviderFactory(
                redirectURL: EnableBankingProviderFactory.defaultRedirectURL,
                credentialStore: InMemoryEnableBankingCredentialStore(
                    applicationID: "app-id",
                    privateKeyPEM: "key"
                )
            ),
            goCardless: GoCardlessPoCProviderFactory(
                credentialStore: InMemoryGoCardlessCredentialStore()
            )
        )

        #expect(factory.makeBankDataProvider().identifier == ConnectionProvider.gocardless.rawValue)
    }
}
