import Foundation

/// Development/PoC wiring: resolves a GoCardless-backed provider using
/// locally stored developer credentials. Production banking will
/// replace this factory with a server-side gateway; features only see
/// the BankProviderResolving abstraction.
struct GoCardlessPoCProviderFactory: BankProviderResolving {
    let credentialStore: any GoCardlessCredentialStoring

    func makeBankDataProvider() -> any BankDataProvider {
        GoCardlessBankDataProvider { [store = credentialStore] in
            guard let secretID = store.readSecretID(),
                  let secretKey = store.readSecretKey() else {
                throw BankProviderError.missingCredentials
            }
            return GoCardlessCredentials(secretID: secretID, secretKey: secretKey)
        }
    }
}

struct KeychainGoCardlessCredentialStore: GoCardlessCredentialStoring {
    private let keychain = KeychainStore.goCardless

    func save(secretID: String, secretKey: String) throws {
        try keychain.saveGoCardlessSecretID(secretID)
        try keychain.saveGoCardlessSecretKey(secretKey)
    }

    func readSecretID() -> String? { keychain.readGoCardlessSecretID() }
    func readSecretKey() -> String? { keychain.readGoCardlessSecretKey() }

    func deleteAll() {
        keychain.delete(account: "secret_id")
        keychain.delete(account: "secret_key")
    }
}

final class InMemoryGoCardlessCredentialStore: GoCardlessCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secretID: String?
    private var secretKey: String?

    init(secretID: String? = nil, secretKey: String? = nil) {
        self.secretID = secretID
        self.secretKey = secretKey
    }

    func save(secretID: String, secretKey: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.secretID = secretID
        self.secretKey = secretKey
    }

    func readSecretID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secretID
    }

    func readSecretKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secretKey
    }

    func deleteAll() {
        lock.lock()
        defer { lock.unlock() }
        secretID = nil
        secretKey = nil
    }
}
