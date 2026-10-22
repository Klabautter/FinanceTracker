import Foundation
import Security

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

/// WP-MacUX (Keychain-Prompt bei Bankverbindungen): Gespeichert wird
/// primär im Data-Protection-Keychain (`kSecUseDataProtectionKeychain`).
/// Dort hängt der Zugriff am Application-Identifier statt an der ACL des
/// jeweiligen Binarys: Re-Signs (Debug-Builds) und Sandbox-Wechsel
/// lösen keine „möchte deine vertraulichen Informationen verwenden“-
/// Prompts mehr aus. Umgebungen ohne passende Keychain-Entitlements
/// (z. B. ad-hoc-Signaturen, CI) fallen auf die klassische Login-Keychain
/// zurück; ein dort gefundener Eintrag wird best-effort in den
/// DP-Keychain migriert, damit Legacy-Installationen einmalig migrieren
/// und danach prompt-frei laufen.
struct KeychainStore: Sendable {
    let service: String

    func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)

        SecItemDelete(query(account: account, dataProtection: true) as CFDictionary)
        var dpAdd = query(account: account, dataProtection: true)
        dpAdd[kSecValueData as String] = data
        dpAdd[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(dpAdd as CFDictionary, nil) == errSecSuccess {
            return
        }

        // Fallback: klassische Login-Keychain (bisheriges Verhalten).
        SecItemDelete(query(account: account, dataProtection: false) as CFDictionary)
        var legacyAdd = query(account: account, dataProtection: false)
        legacyAdd[kSecValueData as String] = data
        legacyAdd[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(legacyAdd as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func read(account: String) -> String? {
        var result: AnyObject?
        let dpStatus = SecItemCopyMatching(
            query(account: account, dataProtection: true, returnData: true) as CFDictionary,
            &result
        )
        if dpStatus == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }

        var legacyResult: AnyObject?
        let legacyStatus = SecItemCopyMatching(
            query(account: account, dataProtection: false, returnData: true) as CFDictionary,
            &legacyResult
        )
        guard legacyStatus == errSecSuccess, let data = legacyResult as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }

        migrateToDataProtection(value, account: account)
        return value
    }

    func delete(account: String) {
        SecItemDelete(query(account: account, dataProtection: true) as CFDictionary)
        SecItemDelete(query(account: account, dataProtection: false) as CFDictionary)
    }

    private func query(
        account: String,
        dataProtection: Bool,
        returnData: Bool = false
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// Best-effort-Migration: nur bei erfolgreichem Legacy-Lesezugriff
    /// (dann ist der Zugriff erlaubt). Schlägt die DP-Ablage fehl, bleibt
    /// der Legacy-Eintrag erhalten und das Verhalten ist wie bisher.
    private func migrateToDataProtection(_ value: String, account: String) {
        var dpAdd = query(account: account, dataProtection: true)
        dpAdd[kSecValueData as String] = Data(value.utf8)
        dpAdd[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemDelete(query(account: account, dataProtection: true) as CFDictionary)
        guard SecItemAdd(dpAdd as CFDictionary, nil) == errSecSuccess else { return }
        // DP-Ablage erfolgreich → Legacy-Eintrag ausräumen, damit keine
        // zweite Quelle bestehen bleibt.
        SecItemDelete(query(account: account, dataProtection: false) as CFDictionary)
    }
}

extension KeychainStore {
    static let goCardlessCredentialsService = "de.klabautter.FinanceTracker.gocardless"

    static var goCardless: KeychainStore {
        KeychainStore(service: goCardlessCredentialsService)
    }

    func saveGoCardlessSecretID(_ value: String) throws { try save(value, account: "secret_id") }
    func saveGoCardlessSecretKey(_ value: String) throws { try save(value, account: "secret_key") }
    func readGoCardlessSecretID() -> String? { read(account: "secret_id") }
    func readGoCardlessSecretKey() -> String? { read(account: "secret_key") }
}

extension KeychainStore {
    /// Enable Banking: Application ID + privater PEM-Schlüssel
    /// (ausschließlich Keychain, nie Source/Logs).
    static let enableBankingCredentialsService = "de.klabautter.FinanceTracker.enablebanking"

    static var enableBanking: KeychainStore {
        KeychainStore(service: enableBankingCredentialsService)
    }

    func saveEnableBankingApplicationID(_ value: String) throws { try save(value, account: "application_id") }
    func saveEnableBankingPrivateKey(_ value: String) throws { try save(value, account: "private_key") }
    func readEnableBankingApplicationID() -> String? { read(account: "application_id") }
    func readEnableBankingPrivateKey() -> String? { read(account: "private_key") }
    func deleteEnableBankingCredentials() {
        delete(account: "application_id")
        delete(account: "private_key")
    }
}
