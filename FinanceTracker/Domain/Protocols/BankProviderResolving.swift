import Foundation

protocol GoCardlessCredentialStoring: Sendable {
    func save(secretID: String, secretKey: String) throws
    func readSecretID() -> String?
    func readSecretKey() -> String?
    func deleteAll()
}

protocol BankProviderResolving: Sendable {
    func makeBankDataProvider() -> any BankDataProvider
    /// Muss eine Anforderung sein (nicht nur eine Erweiterung): Sonst ruft
    /// ein Aufruf über `any BankProviderResolving` immer den Default auf,
    /// und das Routing nach `Connection.provider` greift nicht.
    func makeBankDataProvider(for connection: Connection) -> any BankDataProvider
}

extension BankProviderResolving {
    /// WP-MacUX: Provider-Auswahl nach Connection.provider. Der Default
    /// bleibt provider-agnostisch (PoC-Verhalten), damit bestehende
    /// Factories unverändert bleiben: das Routing überschreibt ihn.
    func makeBankDataProvider(for connection: Connection) -> any BankDataProvider {
        makeBankDataProvider()
    }
}
