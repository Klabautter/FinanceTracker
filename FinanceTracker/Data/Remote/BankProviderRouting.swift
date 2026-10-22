import Foundation

/// WP-MacUX (Sync „BankProviderError-Fehler 2"): Der Provider einer
/// Connection bestimmt den Endpunkt. Vorher lief der Sync einer
/// Enable-Banking-Connection gegen die GoCardless-API: die EB-Session-ID
/// ergab dort zwangsläufig einen HTTP-Fehler. Das Routing wählt den
/// passenden Provider anhand `Connection.provider`.
struct RoutedBankProviderFactory: BankProviderResolving {
    let enableBanking: EnableBankingProviderFactory
    let goCardless: GoCardlessPoCProviderFactory

    /// Legacy-Einstieg ohne Connection-Kontext (bisheriges Verhalten).
    func makeBankDataProvider() -> any BankDataProvider {
        goCardless.makeBankDataProvider()
    }

    func makeBankDataProvider(for connection: Connection) -> any BankDataProvider {
        switch connection.provider {
        case .enablebanking:
            enableBanking.makeBankDataProvider()
        case .gocardless, .local, .tink, .future, .mock:
            goCardless.makeBankDataProvider()
        }
    }
}
