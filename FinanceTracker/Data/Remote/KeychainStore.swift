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

    /// Speichert per Aktualisieren, nur wenn es noch keinen Eintrag gibt
    /// per Anlegen. Nie erst löschen: Scheiterte danach das Anlegen, wäre
    /// der vorhandene Wert verloren.
    func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        if upsert(data, account: account, dataProtection: true) == errSecSuccess {
            return
        }
        // Fallback: klassische Login-Keychain (ohne passende Berechtigung).
        let status = upsert(data, account: account, dataProtection: false)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func upsert(_ data: Data, account: String, dataProtection: Bool) -> OSStatus {
        let match = query(account: account, dataProtection: dataProtection)
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard update == errSecItemNotFound else { return update }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// Ergebnis eines Lesezugriffs: „gibt es nicht" ist etwas anderes als
    /// „konnte nicht gelesen werden" (gesperrter Schlüsselbund, fehlende
    /// Berechtigung). Nur im ersten Fall ist der Wert wirklich weg.
    enum ReadResult: Equatable, Sendable {
        case found(String)
        case notFound
        case failed(OSStatus)

        var value: String? {
            if case .found(let value) = self { return value }
            return nil
        }
    }

    func read(account: String) -> String? {
        readResult(account: account).value
    }

    func readResult(account: String) -> ReadResult {
        var result: AnyObject?
        let dpStatus = SecItemCopyMatching(
            query(account: account, dataProtection: true, returnData: true) as CFDictionary,
            &result
        )
        if dpStatus == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) {
            return .found(value)
        }

        var legacyResult: AnyObject?
        let legacyStatus = SecItemCopyMatching(
            query(account: account, dataProtection: false, returnData: true) as CFDictionary,
            &legacyResult
        )
        if legacyStatus == errSecSuccess, let data = legacyResult as? Data,
           let value = String(data: data, encoding: .utf8) {
            migrateToDataProtection(value, account: account)
            return .found(value)
        }
        let notFound: Set<OSStatus> = [errSecItemNotFound, errSecMissingEntitlement]
        if notFound.contains(dpStatus), legacyStatus == errSecItemNotFound {
            return .notFound
        }
        return .failed(legacyStatus != errSecItemNotFound ? legacyStatus : dpStatus)
    }

    func delete(account: String) {
        SecItemDelete(query(account: account, dataProtection: true) as CFDictionary)
        SecItemDelete(query(account: account, dataProtection: false) as CFDictionary)
    }

    func query(
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
        // Immer ausdrücklich setzen: Ohne die Angabe wirken SecItemDelete
        // und Co. bei einer App mit eigener Kennung (Provisioning-Profil)
        // auf BEIDE Schlüsselbunde. Das Löschen des alten Eintrags nach dem
        // Umzug hätte sonst auch die neue Kopie entfernt (0.5.3).
        query[kSecUseDataProtectionKeychain as String] = dataProtection
        return query
    }

    /// Best-effort-Migration: nur bei erfolgreichem Legacy-Lesezugriff
    /// (dann ist der Zugriff erlaubt). Schlägt die DP-Ablage fehl, bleibt
    /// der Legacy-Eintrag erhalten und das Verhalten ist wie bisher.
    private func migrateToDataProtection(_ value: String, account: String) {
        guard upsert(Data(value.utf8), account: account, dataProtection: true) == errSecSuccess else { return }
        // Erst wenn die neue Kopie lesbar ist, den alten Eintrag ausräumen,
        // und zwar nur im klassischen Schlüsselbund.
        var check = query(account: account, dataProtection: true, returnData: true)
        check[kSecMatchLimit as String] = kSecMatchLimitOne
        var copied: AnyObject?
        guard SecItemCopyMatching(check as CFDictionary, &copied) == errSecSuccess,
              let data = copied as? Data, String(data: data, encoding: .utf8) == value else { return }
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
