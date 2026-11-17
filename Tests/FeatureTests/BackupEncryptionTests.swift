import Foundation
import Testing

@testable import FinanceTracker

/// Roadmap 9.3: Backups lassen sich mit einem Passwort verschlüsseln.
@Suite("BackupEncryption")
struct BackupEncryptionTests {
    /// Wenige Runden: Der Test prüft das Format, nicht die Rechenzeit.
    private let fastIterations: UInt32 = 1_000
    private let payload = Data("FinanceTracker-Backup mit Kontodaten DE89 3704 0044".utf8)

    @Test("Verschlüsseln und mit demselben Passwort öffnen ergibt den Inhalt")
    func roundTrip() throws {
        let encrypted = try BackupEncryption.encrypt(payload, password: "korrekt pferd batterie", iterations: fastIterations)
        #expect(BackupEncryption.isEncrypted(encrypted))
        #expect(!BackupEncryption.isEncrypted(payload))
        #expect(encrypted.count == payload.count + BackupEncryption.overhead)
        // Der Inhalt steht nicht lesbar in der Datei.
        #expect(encrypted.range(of: Data("DE89".utf8)) == nil)
        #expect(try BackupEncryption.decrypt(encrypted, password: "korrekt pferd batterie") == payload)
    }

    @Test("Falsches Passwort und veränderte Datei öffnen nicht")
    func rejectsWrongPasswordAndTampering() throws {
        let encrypted = try BackupEncryption.encrypt(payload, password: "geheim-geheim", iterations: fastIterations)
        #expect(throws: BackupEncryptionError.wrongPasswordOrDamaged) {
            try BackupEncryption.decrypt(encrypted, password: "geheim-geheiM")
        }
        // Ein Bit im Inhalt, im Salt und in der Rundenzahl: jeweils kein Ergebnis.
        for index in [encrypted.count - 20, 15, 12] {
            var tampered = encrypted
            tampered[index] ^= 0x01
            #expect(throws: BackupEncryptionError.self) {
                try BackupEncryption.decrypt(tampered, password: "geheim-geheim")
            }
        }
        #expect(throws: BackupEncryptionError.wrongPasswordOrDamaged) {
            try BackupEncryption.decrypt(Data(encrypted.prefix(30)), password: "geheim-geheim")
        }
        #expect(throws: BackupEncryptionError.emptyPassword) {
            try BackupEncryption.encrypt(payload, password: "", iterations: fastIterations)
        }
    }

    @Test("Jedes Backup bekommt eigenes Salt und eigene Nonce; Umlaute sind tastaturunabhängig")
    func freshSaltAndNormalizedPassword() throws {
        let first = try BackupEncryption.encrypt(payload, password: "geheim-geheim", iterations: fastIterations)
        let second = try BackupEncryption.encrypt(payload, password: "geheim-geheim", iterations: fastIterations)
        #expect(first != second)

        // „ü" als ein Zeichen und als u + Trema ergeben denselben Schlüssel.
        let composed = "m\u{00FC}nchen-2026"
        let decomposed = "mu\u{0308}nchen-2026"
        let encrypted = try BackupEncryption.encrypt(payload, password: composed, iterations: fastIterations)
        #expect(try BackupEncryption.decrypt(encrypted, password: decomposed) == payload)
    }

    @Test("Neuere Formatversion wird als solche gemeldet; Passwortregeln")
    func versionAndPasswordRules() throws {
        var newer = try BackupEncryption.encrypt(payload, password: "geheim-geheim", iterations: fastIterations)
        newer[8] = 2
        #expect(throws: BackupEncryptionError.unsupportedFormat) {
            try BackupEncryption.decrypt(newer, password: "geheim-geheim")
        }
        #expect(BackupEncryption.passwordProblem("kurz", repeated: "kurz") != nil)
        #expect(BackupEncryption.passwordProblem("lang-genug", repeated: "lang-genuk") != nil)
        #expect(BackupEncryption.passwordProblem("lang-genug", repeated: "lang-genug") == nil)
    }

    @Test("Geschütztes Backup: Export, Öffnen mit Passwort und Wiederherstellungs-Prüfung")
    @MainActor
    func encryptedBackupRestoresThroughTheModel() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.transactionRepository.upsert([Transaction(
            accountID: account.id, source: .manual, externalID: "t1", status: .booked, kind: .purchase,
            amount: Money(amount: -12, currency: .eur), bookedAt: Date(timeIntervalSince1970: 1_790_000_000),
            rawDescription: "REWE", rawMerchantName: "REWE", merchantDisplayName: "REWE"
        )])
        let model = SettingsModel(dependencies: dependencies)

        let document = try #require(await model.prepareBackupExport(includeAttachments: false, password: "geheim-geheim"))
        #expect(BackupEncryption.isEncrypted(document.data))
        // Ohne Passwort ist es kein lesbares Archiv, mit klarer Meldung.
        #expect(throws: BackupError.self) { try BackupRestoreService.prepare(document.data) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("enc-\(UUID().uuidString).ftbackup")
        try document.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await model.prepareRestore(from: url)
        #expect(model.preparedRestore == nil)
        #expect(model.lockedRestore?.fileName == url.lastPathComponent)

        #expect(await model.unlockRestore(password: "falsch-falsch") == false)
        #expect(model.restorePasswordError != nil)
        #expect(model.lockedRestore != nil)

        #expect(await model.unlockRestore(password: "geheim-geheim"))
        #expect(model.lockedRestore == nil)
        #expect(model.restorePasswordError == nil)
        #expect(model.preparedRestore?.backup.transactions.count == 1)
    }
}
