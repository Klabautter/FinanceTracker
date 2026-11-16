import Foundation
import Security
import Testing

@testable import FinanceTracker

/// Verhalten des Schlüsselbunds, ausschließlich mit Wegwerf-Einträgen unter
/// einem eigenen Dienstnamen je Test. Der echte Enable-Banking-Schlüssel
/// (Dienst `de.klabautter.FinanceTracker.enablebanking`) wird nie berührt.
@Suite("KeychainStore-Verhalten", .serialized)
struct KeychainStoreBehaviorTests {
    private func throwawayStore() -> KeychainStore {
        let store = KeychainStore(service: "de.klabautter.FinanceTracker.tests.\(UUID().uuidString)")
        #expect(store.service != KeychainStore.enableBankingCredentialsService)
        return store
    }

    @Test("Speichern, Lesen, Überschreiben und Löschen")
    func roundTrip() throws {
        let store = throwawayStore()
        defer { store.delete(account: "a") }
        #expect(store.readResult(account: "a") == .notFound)
        try store.save("eins", account: "a")
        #expect(store.readResult(account: "a") == .found("eins"))
        // Überschreiben aktualisiert den Eintrag statt ihn erst zu löschen.
        try store.save("zwei", account: "a")
        #expect(store.read(account: "a") == "zwei")
        store.delete(account: "a")
        #expect(store.readResult(account: "a") == .notFound)
    }

    @Test("Eintrag im klassischen Schlüsselbund wird gelesen und bleibt lesbar")
    func legacyEntryIsReadable() throws {
        let store = throwawayStore()
        defer { store.delete(account: "legacy") }
        var add = store.query(account: "legacy", dataProtection: false)
        add[kSecValueData as String] = Data("alt".utf8)
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)

        #expect(store.read(account: "legacy") == "alt")
        // Nach einem möglichen Umzug ist der Wert weiter genau einmal lesbar.
        #expect(store.read(account: "legacy") == "alt")
    }

    @Test("Zugangsdaten-Ablage merkt sich ‚kein Schlüssel‘ und liest gespeicherte Werte")
    func credentialStoreOnThrowawayService() throws {
        let keychain = throwawayStore()
        defer {
            keychain.delete(account: "credentials")
            keychain.deleteEnableBankingCredentials()
        }
        let store = KeychainEnableBankingCredentialStore(keychain: keychain)
        #expect(store.readApplicationID() == nil)
        try store.save(applicationID: "app-1", privateKeyPEM: "pem")
        #expect(store.readApplicationID() == "app-1")
        let fresh = KeychainEnableBankingCredentialStore(keychain: keychain)
        #expect(fresh.readPrivateKey() == "pem")
        fresh.deleteAll()
        #expect(KeychainEnableBankingCredentialStore(keychain: keychain).readApplicationID() == nil)
    }
}
