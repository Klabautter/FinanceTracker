import CommonCrypto
import CryptoKit
import Foundation

enum BackupEncryptionError: LocalizedError, Equatable {
    case emptyPassword
    /// Falsches Passwort oder veränderte Datei: AES-GCM kann beides nicht
    /// unterscheiden, und die App behauptet es deshalb auch nicht.
    case wrongPasswordOrDamaged
    case unsupportedFormat
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            String(localized: "Bitte ein Passwort eingeben.")
        case .wrongPasswordOrDamaged:
            String(localized: "Das Passwort passt nicht zu diesem Backup, oder die Datei ist beschädigt.")
        case .unsupportedFormat:
            String(localized: "Dieses verschlüsselte Backup stammt aus einer neueren Version der App.")
        case .keyDerivationFailed:
            String(localized: "Der Schlüssel für das Backup konnte nicht berechnet werden.")
        }
    }
}

/// Optionaler Passwortschutz für Backups (Roadmap 9.3).
///
/// Verschlüsselt wird das fertige Archiv als Ganzes, damit auch Dateinamen
/// und Manifest nichts verraten. Verfahren: Schlüssel aus dem Passwort über
/// PBKDF2-HMAC-SHA256 mit zufälligem Salt, Inhalt mit AES-256-GCM. Der Kopf
/// (Kennung, Version, Rundenzahl, Salt) ist mit authentifiziert: Wer ihn
/// ändert, bekommt kein Ergebnis. Das Passwort wird nirgends gespeichert.
///
/// Aufbau der Datei: `FTBKENC1` (8) · Version (1) · Runden (4, big endian) ·
/// Salt (16) · AES-GCM (Nonce 12 · Inhalt · Tag 16).
enum BackupEncryption {
    static let magic = Data("FTBKENC1".utf8)
    static let version: UInt8 = 1
    /// OWASP-Empfehlung für PBKDF2-HMAC-SHA256 (2023).
    static let defaultIterations: UInt32 = 600_000
    static let saltLength = 16
    static let minimumPasswordLength = 8
    private static let headerLength = 8 + 1 + 4 + 16
    /// Obergrenze beim Öffnen: Eine Datei darf die App nicht minutenlang
    /// rechnen lassen.
    private static let maximumIterations: UInt32 = 10_000_000

    /// Zusätzliche Bytes gegenüber dem unverschlüsselten Archiv.
    static let overhead = headerLength + 12 + 16

    static func isEncrypted(_ data: Data) -> Bool {
        data.count >= magic.count && data.prefix(magic.count) == magic
    }

    static func encrypt(_ plaintext: Data, password: String, iterations: UInt32 = defaultIterations) throws -> Data {
        guard !password.isEmpty else { throw BackupEncryptionError.emptyPassword }
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<saltLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        var header = magic
        header.append(version)
        header.append(contentsOf: withUnsafeBytes(of: iterations.bigEndian) { Array($0) })
        header.append(salt)

        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = sealed.combined else { throw BackupEncryptionError.keyDerivationFailed }
        return header + combined
    }

    static func decrypt(_ data: Data, password: String) throws -> Data {
        guard !password.isEmpty else { throw BackupEncryptionError.emptyPassword }
        let bytes = Data(data) // eigene, bei 0 beginnende Indizes
        guard isEncrypted(bytes), bytes.count > headerLength + 12 + 16 else {
            throw BackupEncryptionError.wrongPasswordOrDamaged
        }
        guard bytes[8] == version else { throw BackupEncryptionError.unsupportedFormat }
        let iterations = bytes[9..<13].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard iterations > 0, iterations <= maximumIterations else {
            throw BackupEncryptionError.wrongPasswordOrDamaged
        }
        let header = bytes.prefix(headerLength)
        let salt = Data(bytes[13..<headerLength])
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: Data(bytes.dropFirst(headerLength)))
            return try AES.GCM.open(box, using: key, authenticating: Data(header))
        } catch {
            throw BackupEncryptionError.wrongPasswordOrDamaged
        }
    }

    /// Was beim Festlegen eines Passworts nicht stimmt; `nil`, wenn es passt.
    static func passwordProblem(_ password: String, repeated: String) -> String? {
        if password.count < minimumPasswordLength {
            return String(localized: "Das Passwort braucht mindestens \(minimumPasswordLength) Zeichen.")
        }
        if password != repeated {
            return String(localized: "Die beiden Eingaben stimmen nicht überein.")
        }
        return nil
    }

    private static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        // Einheitliche Zeichenform, damit dasselbe Passwort auf jeder
        // Tastatur denselben Schlüssel ergibt („ü" als ein oder zwei Zeichen).
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations,
                &derived, derived.count
            )
        }
        guard status == kCCSuccess else { throw BackupEncryptionError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }
}
