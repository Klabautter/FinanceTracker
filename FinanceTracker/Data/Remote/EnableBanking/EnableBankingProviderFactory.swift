import Foundation

/// Enable Banking Provider-Wiring: liest Application ID + privaten
/// PEM-Schlüssel aus dem Keychain und liefert den Provider.
struct EnableBankingProviderFactory: BankProviderResolving {
    /// Redirect-URL, die im Control Panel für die Anwendung registriert ist.
    /// Für den Dev-Flow (Redirect-URL einfügen) fachlich beliebig, aber
    /// whitelist-konsistent.
    static let defaultRedirectURL = "https://enablebanking.com/redirect"

    let redirectURL: String
    let credentialStore: any EnableBankingCredentialStoring

    func makeBankDataProvider() -> any BankDataProvider {
        EnableBankingBankDataProvider(
            redirectURL: redirectURL,
            transport: URLSessionTransport()
        ) { [store = credentialStore] in
            guard let applicationID = store.readApplicationID(), !applicationID.isEmpty,
                  let privateKeyPEM = store.readPrivateKey(), !privateKeyPEM.isEmpty else {
                throw BankProviderError.missingCredentials
            }
            return EnableBankingCredentials(applicationID: applicationID, privateKeyPEM: privateKeyPEM)
        }
    }
}

protocol EnableBankingCredentialStoring: Sendable {
    func save(applicationID: String, privateKeyPEM: String) throws
    func readApplicationID() -> String?
    func readPrivateKey() -> String?
    func deleteAll()
}

/// Zugangsdaten im Schlüsselbund, pro App-Lauf einmal gelesen.
///
/// Ohne Apple-Team-ID merkt sich macOS die Schlüsselbund-Freigabe nur für
/// genau diesen Build. Jeder Lesezugriff kann deshalb eine Passwortabfrage
/// auslösen. Darum: ein einziger Eintrag für Application ID und Schlüssel
/// (eine Abfrage statt zwei), einmal gelesen und im Arbeitsspeicher
/// gehalten. Eine Instanz pro App (AppDependencies).
final class KeychainEnableBankingCredentialStore: EnableBankingCredentialStoring, @unchecked Sendable {
    private struct Stored: Codable {
        let applicationID: String
        let privateKeyPEM: String
    }

    private static let combinedAccount = "credentials"

    private let keychain = KeychainStore.enableBanking
    private let lock = NSLock()
    private var cached: Stored?
    private var hasLoaded = false

    func save(applicationID: String, privateKeyPEM: String) throws {
        let stored = Stored(applicationID: applicationID, privateKeyPEM: privateKeyPEM)
        try write(stored)
        // Frühere Einzeleinträge entfallen.
        keychain.delete(account: "application_id")
        keychain.delete(account: "private_key")
        lock.withLock {
            cached = stored
            hasLoaded = true
        }
    }

    func readApplicationID() -> String? { load()?.applicationID }
    func readPrivateKey() -> String? { load()?.privateKeyPEM }

    func deleteAll() {
        keychain.delete(account: Self.combinedAccount)
        keychain.deleteEnableBankingCredentials()
        lock.withLock {
            cached = nil
            hasLoaded = true
        }
    }

    private func load() -> Stored? {
        lock.lock()
        defer { lock.unlock() }
        if hasLoaded { return cached }
        hasLoaded = true
        if let json = keychain.read(account: Self.combinedAccount),
           let stored = try? JSONDecoder().decode(Stored.self, from: Data(json.utf8)) {
            cached = stored
            return stored
        }
        // Bestand aus zwei Einzeleinträgen: einmalig zusammenlegen.
        guard let applicationID = keychain.readEnableBankingApplicationID(),
              let privateKey = keychain.readEnableBankingPrivateKey() else { return nil }
        let stored = Stored(applicationID: applicationID, privateKeyPEM: privateKey)
        if (try? write(stored)) != nil {
            keychain.delete(account: "application_id")
            keychain.delete(account: "private_key")
        }
        cached = stored
        return stored
    }

    private func write(_ stored: Stored) throws {
        let json = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        try keychain.save(json, account: Self.combinedAccount)
    }
}

/// Flüchtiger Credential-Store für isolierte App-Läufe, Tests und Previews.
///
/// Der Typ ist bewusst in allen Build-Konfigurationen verfügbar: Der
/// `-ui-testing-empty`-/Storage-Recovery-Startpfad wird auch vom release-nahen
/// Performance-Scheme kompiliert. Persistiert wird hier grundsätzlich nichts.
final class InMemoryEnableBankingCredentialStore: EnableBankingCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var applicationID: String?
    private var privateKeyPEM: String?

    init(applicationID: String?, privateKeyPEM: String?) {
        self.applicationID = applicationID
        self.privateKeyPEM = privateKeyPEM
    }

    func save(applicationID: String, privateKeyPEM: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.applicationID = applicationID
        self.privateKeyPEM = privateKeyPEM
    }

    func readApplicationID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return applicationID
    }

    func readPrivateKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return privateKeyPEM
    }

    func deleteAll() {
        lock.lock()
        defer { lock.unlock() }
        applicationID = nil
        privateKeyPEM = nil
    }
}
