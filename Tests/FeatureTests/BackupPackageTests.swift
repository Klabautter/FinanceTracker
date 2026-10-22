import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

/// WP29: Vollständiges Backup: Occurrences, Attachments (Metadaten +
/// Bytes), Splits, Budget-History; ohne Secrets; Package-Format.
@MainActor
@Suite("BackupPackage")
struct BackupPackageTests {

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    @Test("Restore erkennt beschädigte Belegdaten durch die ZIP-Prüfsumme")
    func damagedAttachmentRejected() throws {
        let payload = Data("Ein unveränderter Beleg".utf8)
        var archive = try BackupArchiveWriter.archive(entries: [.init(name: "receipt.txt", data: payload)])
        let range = try #require(archive.range(of: payload))
        archive[range.lowerBound] ^= 1
        let reader = try ZipArchiveReader(data: archive, verifyChecksums: true)
        #expect(throws: ZipArchiveError.self) { try reader.extractEntry("receipt.txt") }
    }

    @Test("Vollrestore ersetzt gleiche IDs, entfernt Altbestände und stellt Belege wieder her")
    func fullRestoreReplacesExistingStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataStore(url: directory.appendingPathComponent("test.store"))
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Gesichert", type: .checking, currency: .eur, source: .manual)
        let merchant = Merchant(displayName: "Händler", aliases: ["alias"])
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.merchantRepository.upsert([merchant])
        let transaction = Transaction(accountID: account.id, source: .manual, externalID: "restore", status: .booked,
            kind: .purchase, amount: Money(amount: -42, currency: .eur), bookedAt: Date(),
            rawDescription: "Gesichert", rawMerchantName: "Händler", merchantID: merchant.id, merchantDisplayName: "Händler")
        try await dependencies.transactionRepository.upsert([transaction])
        let attachment = TransactionAttachment(transactionID: transaction.id, fileName: "Beleg.pdf", mimeType: "application/pdf", localRelativePath: "nested/Beleg.pdf")
        try await dependencies.transactionAttachmentRepository.add(attachment)
        let backup = try await BackupService.makeBackup(dependencies: dependencies)
        let payload = Data("Beleginhalt".utf8)
        let package = try BackupService.package(backup: backup,
            attachmentFiles: [.init(relativePath: attachment.localRelativePath, data: payload)], appVersion: "Test")
        let prepared = try BackupRestoreService.prepare(package)
        var changed = account
        changed.name = "Verändert"
        try await dependencies.accountRepository.upsert([changed, Account(name: "Entfernen", type: .checking, currency: .eur, source: .manual)])
        let files = directory.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data("Alt".utf8).write(to: files.appendingPathComponent("alt.txt"))
        try await #require(dependencies.backupRestoreService).replace(with: prepared, attachmentsDirectory: files)
        let restoredAccounts = try await dependencies.accountRepository.accounts()
        #expect(restoredAccounts.count == 1)
        #expect(restoredAccounts.first?.name == "Gesichert")
        #expect(try await dependencies.merchantRepository.merchants().first?.aliases == ["alias"])
        let restoredAttachment = try #require(await dependencies.transactionAttachmentRepository.allAttachments().first)
        #expect(restoredAttachment.id == attachment.id)
        #expect(try Data(contentsOf: files.appendingPathComponent(restoredAttachment.localRelativePath)) == payload)
        // Unreferenced old files remain recoverable, including across process interruption.
        #expect(try Data(contentsOf: files.appendingPathComponent("alt.txt")) == Data("Alt".utf8))
        // A fresh container verifies the committed on-disk result, not the actor cache.
        let reopened = try SwiftDataStore(url: directory.appendingPathComponent("test.store"))
        let fresh = AppDependencies.make(container: reopened.container, baseCurrency: .eur)
        #expect(try await fresh.accountRepository.accounts().map(\.id) == [account.id])
        #expect(try await fresh.transactionRepository.transactions(matching: TransactionQuery()).map(\.id) == [transaction.id])
    }

    @Test("Restore lehnt fehlende Referenzen und unvollständige Belege vor Änderungen ab")
    func restoreRejectsIncompletePackages() async throws {
        let dependencies = try makeDependencies()
        let transaction = Transaction(accountID: UUID(), source: .manual, externalID: "orphan", status: .booked,
            kind: .purchase, amount: Money(amount: -1, currency: .eur), bookedAt: Date(),
            rawDescription: "Ungültig", rawMerchantName: "Ungültig", merchantDisplayName: "Ungültig")
        try await dependencies.transactionRepository.upsert([transaction])
        let orphan = try await BackupService.makeBackup(dependencies: dependencies)
        #expect(throws: BackupError.self) { try BackupRestoreService.prepare(BackupService.package(backup: orphan, attachmentFiles: [], appVersion: "Test")) }
        #expect(throws: BackupError.self) { try BackupRestoreService.validatePath("../secret") }
        #expect(throws: BackupError.self) { try BackupRestoreService.validatePath("/absolute") }
        let account = Account(id: transaction.accountID, name: "Konto", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.transactionAttachmentRepository.add(TransactionAttachment(transactionID: transaction.id, fileName: "Fehlt.pdf", mimeType: "application/pdf", localRelativePath: "missing.pdf"))
        let incomplete = try await BackupService.makeBackup(dependencies: dependencies)
        #expect(throws: BackupError.self) { try BackupRestoreService.prepare(BackupService.package(backup: incomplete, attachmentFiles: [], appVersion: "Test")) }
        #expect(try await dependencies.accountRepository.accounts().count == 1)
    }

    @Test("Backup enthält Occurrences, Splits, Budget-History und Attachment-Metadaten")
    func backupContainsAllEntities() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let commitment = RecurringCommitment(
            name: "Miete",
            merchantKey: "MIETE",
            direction: .expense,
            cadence: .monthly,
            amountPolicy: .fixed,
            expectedAmount: 985,
            currency: .eur
        )
        try await dependencies.recurringCommitmentRepository.upsert([commitment])

        let txn = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .demo,
            externalID: "bkp-1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -985, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Miete",
            rawMerchantName: "Miete",
            merchantDisplayName: "Miete",
            tagIDs: []
        )
        try await dependencies.transactionRepository.upsert([txn])
        let collection = try TransactionCollection(
            name: "Urlaub",
            systemIconName: "airplane",
            startDate: txn.displayDate.addingTimeInterval(-60),
            endDateExclusive: txn.displayDate.addingTimeInterval(60),
            accountIDs: [account.id]
        )
        try await dependencies.transactionCollectionRepository.upsert([collection])
        try await dependencies.transactionCollectionOverrideRepository.upsert([
            TransactionCollectionOverride(
                collectionID: collection.id,
                transactionID: txn.id,
                decision: .include
            )
        ])
        try await dependencies.recurringCommitmentRepository.addOccurrence(
            RecurringOccurrence(commitmentID: commitment.id, transactionID: txn.id)
        )
        try await dependencies.transactionSplitRepository.upsert([
            TransactionSplitLine(parentTransactionID: txn.id, amount: 985)
        ])
        try await dependencies.budgetRepository.upsert([
            Budget(name: "Wohnen", amount: 1000)
        ])
        try await dependencies.budgetRepository.upsertAmountHistory(
            BudgetAmountHistory(budgetID: try #require((try await dependencies.budgetRepository.budgets()).first).id,
                                periodStart: Date(), amount: 900)
        )

        let backup = try await BackupService.makeBackup(dependencies: dependencies)
        #expect(backup.recurringOccurrences.count == 1)  // §198: nicht mehr hardcoded []
        #expect(backup.splitLines.count == 1)
        // Roadmap #99: budgetRepository.upsert historisiert den aktuellen
        // Monat automatisch, der zusätzliche 900er-Eintrag kommt dazu.
        #expect(backup.budgetAmountHistory.contains { $0.amount == 900 })
        #expect(backup.tags.isEmpty)
        #expect(backup.transactionCollections == [collection])
        #expect(backup.transactionCollectionOverrides.count == 1)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("restore-all-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let restoredDependencies = try makeDependencies()
        let prepared = try BackupRestoreService.prepare(BackupService.package(backup: backup, attachmentFiles: [], appVersion: "Test"))
        try await #require(restoredDependencies.backupRestoreService).replace(with: prepared, attachmentsDirectory: directory)
        let restored = try await BackupService.makeBackup(dependencies: restoredDependencies)
        // Das versionierte JSON-Format speichert Zeitpunkte sekundengenau.
        let serialized = try BackupService.decode(BackupService.encode(backup))
        #expect(restored.accounts == serialized.accounts)
        #expect(restored.transactions == serialized.transactions)
        #expect(restored.recurringCommitments == serialized.recurringCommitments)
        #expect(restored.recurringOccurrences == serialized.recurringOccurrences)
        #expect(restored.splitLines == serialized.splitLines)
        #expect(restored.budgets == serialized.budgets)
        #expect(Set(restored.budgetAmountHistory.map(\.id)) == Set(serialized.budgetAmountHistory.map(\.id)))
        #expect(restored.transactionCollections == serialized.transactionCollections)
        #expect(restored.transactionCollectionOverrides == serialized.transactionCollectionOverrides)

        // Encode/Decode bewahrt die Occurrence.
        let roundtrip = try BackupService.decode(BackupService.encode(backup))
        #expect(roundtrip.recurringOccurrences.count == 1)
        #expect(roundtrip.recurringOccurrences.first?.commitmentID == commitment.id)
        #expect(roundtrip.formatVersion == FinanceTrackerBackup.formatVersion)
        #expect(roundtrip.transactionCollections.map(\.id) == [collection.id])
        #expect(roundtrip.transactionCollections.first?.accountIDs == collection.accountIDs)

        let importedDependencies = try makeDependencies()
        try await BackupService.importTransactionCollections(
            from: roundtrip,
            dependencies: importedDependencies
        )
        #expect(try await importedDependencies.transactionCollectionRepository.collection(id: collection.id) != nil)
        #expect(try await importedDependencies.transactionCollectionOverrideRepository.override(
            collectionID: collection.id,
            transactionID: txn.id
        )?.decision == .include)
    }

    @Test("Package enthält Manifest, data.json und Attachment-Bytes")
    func packageContainsManifestAndFiles() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let txn = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .demo,
            externalID: "bkp-att-1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -10, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Beleg",
            rawMerchantName: "Beleg",
            merchantDisplayName: "Beleg"
        )
        try await dependencies.transactionRepository.upsert([txn])

        // Attachment mit echter Datei im Attachments-Verzeichnis (Temp-Domain).
        let service = AttachmentService(
            attachmentsBaseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("bkp-att-\(UUID().uuidString)", isDirectory: true)
        )
        let payload = Data("PDF-BYTES-FIXTURE".utf8)
        let stored = try service.store(
            data: payload,
            fileName: "beleg.pdf",
            mimeType: "application/pdf",
            transactionID: txn.id
        )
        try await dependencies.transactionAttachmentRepository.add(
            TransactionAttachment(
                transactionID: txn.id,
                fileName: "beleg.pdf",
                mimeType: "application/pdf",
                localRelativePath: stored.relativePath
            )
        )

        // makeBackupPackage nutzt defaultBaseDirectory, für den Test bauen
        // wir das Package aus dem Backup + Service-Bytes manuell zusammen.
        let backup = try await BackupService.makeBackup(dependencies: dependencies)
        #expect(backup.attachments.count == 1)
        #expect(backup.attachments.first?.localRelativePath == stored.relativePath)

        let packageData = try BackupService.package(
            backup: backup,
            attachmentFiles: [BackupAttachmentFile(
                relativePath: stored.relativePath,
                data: payload
            )],
            appVersion: "0.1.0 (1)"
        )

        // Package lesbar mit dem bestehenden Zip-Reader.
        let reader = try ZipArchiveReader(data: packageData)
        let manifest = try reader.extractEntry("manifest.json")
        #expect(String(data: manifest, encoding: .utf8)?.contains("\"attachmentCount\" : 1") == true
            || String(data: manifest, encoding: .utf8)?.contains("\"attachmentCount\": 1") == true)

        let dataJSON = try reader.extractEntry("data.json")
        let dataString = String(data: dataJSON, encoding: .utf8) ?? ""
        #expect(dataString.contains("recurringOccurrences"))
        #expect(dataString.contains("attachments"))
        #expect(!dataString.contains("accessToken"))
        #expect(!dataString.contains("secret"))

        let attachmentBytes = try reader.extractEntry("attachments/\(stored.relativePath)")
        #expect(attachmentBytes == payload)

        let imported = try BackupService.decodePackage(packageData)
        #expect(imported.attachments.map(\.id) == backup.attachments.map(\.id))
        #expect(imported.transactionCollections == backup.transactionCollections)

        // Aufräumen
        try? service.delete(relativePath: stored.relativePath)
    }

    @Test("Fehlende Attachment-Datei schlägt kontrolliert fehl")
    func missingAttachmentFileFails() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        let txn = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .demo,
            externalID: "bkp-att-missing",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -10, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Beleg",
            rawMerchantName: "Beleg",
            merchantDisplayName: "Beleg"
        )
        try await dependencies.transactionRepository.upsert([txn])
        try await dependencies.transactionAttachmentRepository.add(
            TransactionAttachment(
                transactionID: txn.id,
                fileName: "phantom.pdf",
                mimeType: "application/pdf",
                localRelativePath: "phantom/missing.pdf"
            )
        )

        _ = try await BackupService.makeBackup(dependencies: dependencies)
        // Direkter Service-Pfad: makeBackupPackage wirft kontrolliert, wenn
        // die Attachment-Datei fehlt (§17/§18: kein stiller Fallback).
        await #expect(throws: BackupError.attachmentFileMissing("phantom/missing.pdf")) {
            try await BackupService.makeBackupPackage(dependencies: dependencies)
        }
    }

    @Test("Verbindungen im Backup enthalten keine Secrets")
    func connectionsContainNoSecrets() async throws {
        let dependencies = try makeDependencies()
        let backup = try await BackupService.makeBackup(dependencies: dependencies)
        let json = String(data: try BackupService.encode(backup), encoding: .utf8) ?? ""

        // Struktur-Check: Keine Keychain-/Token-Felder im Backup-JSON.
        #expect(!json.lowercased().contains("accesstoken"))
        #expect(!json.lowercased().contains("secret"))
        #expect(!json.lowercased().contains("keychain"))
        #expect(!json.lowercased().contains("authorization"))
    }

    /// WP17 (§123-125): Gesamtspeicher-Policy: Belege über dem Limit
    /// schlagen kontrolliert fehl; „ohne Belege" bleibt möglich.
    @Test("Attachment-Gesamtgröße über Limit → kontrollierter Fehler; ohne Belege erfolgreich")
    func attachmentBudgetBehavior() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let txn = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .demo,
            externalID: "bkp-budget-1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -10, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Beleg",
            rawMerchantName: "Beleg",
            merchantDisplayName: "Beleg"
        )
        try await dependencies.transactionRepository.upsert([txn])

        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bkp-budget-\(UUID().uuidString)", isDirectory: true)
        let service = AttachmentService(attachmentsBaseDirectory: baseDirectory)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let payload = Data(repeating: 0x41, count: 4 * 1024) // 4 KB
        let stored = try service.store(
            data: payload,
            fileName: "beleg.pdf",
            mimeType: "application/pdf",
            transactionID: txn.id
        )
        try await dependencies.transactionAttachmentRepository.add(
            TransactionAttachment(
                transactionID: txn.id,
                fileName: "beleg.pdf",
                mimeType: "application/pdf",
                localRelativePath: stored.relativePath
            )
        )

        // 1) Limit knapp unter der Dateigröße → kontrollierter Fehler.
        await #expect(throws: BackupError.attachmentBudgetExceeded(totalBytes: 4 * 1024, limitBytes: 1024)) {
            try await BackupService.makeBackupPackage(
                dependencies: dependencies,
                includeAttachments: true,
                maxTotalAttachmentBytes: 1024,
                attachmentsBaseDirectory: baseDirectory
            )
        }

        // 2) Ohne Belege: erfolgreich, manifest attachmentCount 0, aber
        //    Metadaten in data.json.
        let dataOnly = try await BackupService.makeBackupPackage(
            dependencies: dependencies,
            includeAttachments: false,
            attachmentsBaseDirectory: baseDirectory
        )
        let reader = try ZipArchiveReader(data: dataOnly)
        let manifest = String(data: try reader.extractEntry("manifest.json"), encoding: .utf8) ?? ""
        #expect(manifest.contains("\"attachmentCount\" : 0") || manifest.contains("\"attachmentCount\": 0"))
        let dataString = String(data: try reader.extractEntry("data.json"), encoding: .utf8) ?? ""
        #expect(dataString.contains("beleg.pdf"))
    }

    @Test("V2-Backup migriert explizit mit leeren Collections auf V4")
    func legacyBackupMigration() async throws {
        let dependencies = try makeDependencies()
        let current = try await BackupService.makeBackup(dependencies: dependencies)
        var object = try #require(
            JSONSerialization.jsonObject(with: BackupService.encode(current)) as? [String: Any]
        )
        object["formatVersion"] = 2
        object.removeValue(forKey: "transactionCollections")
        object.removeValue(forKey: "transactionCollectionOverrides")

        let migrated = try BackupService.decode(JSONSerialization.data(withJSONObject: object))
        #expect(migrated.formatVersion == 4)
        #expect(migrated.transactionCollections.isEmpty)
        #expect(migrated.transactionCollectionOverrides.isEmpty)
    }

    @Test("V3 maskiert fehlende oder korrupte Collection-Daten nicht")
    func corruptCurrentCollectionDataFails() async throws {
        let dependencies = try makeDependencies()
        let current = try await BackupService.makeBackup(dependencies: dependencies)
        var missing = try #require(
            JSONSerialization.jsonObject(with: BackupService.encode(current)) as? [String: Any]
        )
        missing.removeValue(forKey: "transactionCollections")
        #expect(throws: (any Error).self) {
            _ = try BackupService.decode(JSONSerialization.data(withJSONObject: missing))
        }

        let collection = try TransactionCollection(
            name: "Test",
            systemIconName: "tray",
            startDate: Date(timeIntervalSince1970: 1),
            endDateExclusive: Date(timeIntervalSince1970: 2),
            accountIDs: [UUID()]
        )
        try await dependencies.transactionCollectionRepository.upsert([collection])
        try await dependencies.transactionCollectionOverrideRepository.upsert([
            TransactionCollectionOverride(
                collectionID: collection.id,
                transactionID: UUID(),
                decision: .include
            )
        ])
        let populated = try await BackupService.makeBackup(dependencies: dependencies)
        var corrupt = try #require(
            JSONSerialization.jsonObject(with: BackupService.encode(populated)) as? [String: Any]
        )
        var overrides = try #require(corrupt["transactionCollectionOverrides"] as? [[String: Any]])
        overrides[0]["decision"] = "future-decision"
        corrupt["transactionCollectionOverrides"] = overrides

        #expect(throws: (any Error).self) {
            _ = try BackupService.decode(JSONSerialization.data(withJSONObject: corrupt))
        }
    }

    /// P2 (#27/#34): Gruppenanteile sind als optionales V4-Feld im Backup
    /// Roundtrip erhält sie, V4 ohne Key liest als [] (kein Bump, lesbar).
    @Test("Backup-Roundtrip erhält SharedExpenseShares; V4 ohne Key liest als leer")
    func backupRoundtripWithShares() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        let txn = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .demo,
            externalID: "bkp-share-1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -90, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Abendessen",
            rawMerchantName: "Ristorante",
            merchantDisplayName: "Ristorante"
        )
        try await dependencies.transactionRepository.upsert([txn])
        let share = try SharedExpenseShare(
            transactionID: txn.id,
            paidBy: "Alex",
            owedBy: "Mara",
            shareAmount: 30,
            shareCurrency: .eur
        )
        try await dependencies.sharedExpenseShareRepository.upsert([share])

        let backup = try await BackupService.makeBackup(dependencies: dependencies)
        #expect(backup.sharedExpenseShares.count == 1)
        #expect(backup.sharedExpenseShares.first?.id == share.id)

        // Encode/Decode-Roundtrip erhält die Anteile (keine Secrets im JSON).
        // Feldvergleich statt Voll-Equality: ISO8601 rundet Sub-Sekunden.
        let roundtrip = try BackupService.decode(BackupService.encode(backup))
        let restored = try #require(roundtrip.sharedExpenseShares.first)
        #expect(roundtrip.sharedExpenseShares.count == 1)
        #expect(restored.id == share.id)
        #expect(restored.transactionID == share.transactionID)
        #expect(restored.paidBy == share.paidBy)
        #expect(restored.owedBy == share.owedBy)
        #expect(restored.shareAmount == share.shareAmount)
        #expect(restored.shareCurrency == share.shareCurrency)
        #expect(restored.settled == share.settled)
        #expect(roundtrip.formatVersion == FinanceTrackerBackup.formatVersion)
        let json = String(data: try BackupService.encode(backup), encoding: .utf8) ?? ""
        #expect(!json.lowercased().contains("accesstoken"))
        #expect(!json.lowercased().contains("secret"))

        // V4 ohne den Key (altes Backup) bleibt lesbar → leere Anteile.
        var object = try #require(
            JSONSerialization.jsonObject(with: BackupService.encode(backup)) as? [String: Any]
        )
        object.removeValue(forKey: "sharedExpenseShares")
        let legacy = try BackupService.decode(JSONSerialization.data(withJSONObject: object))
        #expect(legacy.sharedExpenseShares.isEmpty)
    }
}
