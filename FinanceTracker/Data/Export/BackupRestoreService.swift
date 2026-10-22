import Foundation
import SwiftData

/// Validated, immutable input. Only the preparation step can construct it.
struct PreparedBackupRestore: Sendable {
    let backup: FinanceTrackerBackup
    let files: [BackupAttachmentFile]
    var summary: String {
        Self.summary(
            accounts: backup.accounts.count,
            transactions: backup.transactions.count,
            budgets: backup.budgets.count,
            attachments: files.count
        )
    }

    /// Inhaltsangabe mit korrekter Einzahl („1 Konto", nicht „1 Konten").
    static func summary(accounts: Int, transactions: Int, budgets: Int, attachments: Int) -> String {
        return [
            accounts == 1 ? String(localized: "1 Konto") : String(localized: "\(accounts) Konten"),
            transactions == 1 ? String(localized: "1 Buchung") : String(localized: "\(transactions) Buchungen"),
            budgets == 1 ? String(localized: "1 Budget") : String(localized: "\(budgets) Budgets"),
            attachments == 1 ? String(localized: "1 Beleg") : String(localized: "\(attachments) Belege")
        ].joined(separator: " · ")
    }
    fileprivate init(backup: FinanceTrackerBackup, files: [BackupAttachmentFile]) {
        self.backup = backup
        self.files = files
    }
}

/// Files are written to a new generation before the single database commit.
/// A process interruption leaves either the old references or fully written new files.
/// Old files are retained for recovery; no destructive directory swap is needed.
actor BackupRestoreService {
    private let persistence: PersistenceModelActor
    init(modelContainer: ModelContainer) {
        persistence = PersistenceModelActor(modelContainer: modelContainer)
    }

    nonisolated static let maxArchiveBytes = BackupService.maxTotalAttachmentBytesDefault + 50 * 1024 * 1024

    nonisolated static func prepare(_ data: Data) throws -> PreparedBackupRestore {
        let archive = try ZipArchiveReader(data: data, maxArchiveBytes: maxArchiveBytes, maxEntryBytes: maxArchiveBytes, verifyChecksums: true)
        guard Set(archive.entryNames).count == archive.entryNames.count else {
            throw BackupError.invalidRestore(String(localized: "Doppelte Dateien im Archiv."))
        }
        let dataJSON = try archive.extractEntry("data.json")
        struct SourceVersion: Decodable { let formatVersion: Int }
        let sourceVersion = try JSONDecoder().decode(SourceVersion.self, from: dataJSON).formatVersion
        let backup = try BackupService.decode(dataJSON)
        try validate(backup)
        struct Manifest: Decodable { let formatVersion: Int; let attachmentCount: Int }
        let manifest = try JSONDecoder().decode(Manifest.self, from: archive.extractEntry("manifest.json"))
        guard manifest.formatVersion == sourceVersion,
              manifest.attachmentCount == backup.attachments.count else {
            throw BackupError.invalidRestore(String(localized: "Das Backup enthält nicht alle Belege. Für die Wiederherstellung ist ein vollständiges Backup erforderlich."))
        }
        let expectedEntries = Set(["manifest.json", "data.json"] + backup.attachments.map { "attachments/\($0.localRelativePath)" })
        guard Set(archive.entryNames) == expectedEntries else {
            throw BackupError.invalidRestore(String(localized: "Das Archiv enthält unerwartete Dateien."))
        }
        var total = 0
        let files = try backup.attachments.map { attachment in
            try validatePath(attachment.localRelativePath)
            let name = "attachments/\(attachment.localRelativePath)"
            guard let size = archive.uncompressedSize(ofEntry: name), size > 0 else {
                throw BackupError.attachmentFileMissing(attachment.localRelativePath)
            }
            total += size
            guard total <= BackupService.maxTotalAttachmentBytesDefault else {
                throw BackupError.invalidRestore(String(localized: "Belege überschreiten die zulässige Gesamtgröße."))
            }
            return BackupAttachmentFile(relativePath: attachment.localRelativePath, data: try archive.extractEntry(name))
        }
        return PreparedBackupRestore(backup: backup, files: files)
    }

    nonisolated static func validatePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.contains("\0"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw BackupError.invalidRestore(String(localized: "Ungültiger Belegpfad."))
        }
    }

    nonisolated static func validate(_ backup: FinanceTrackerBackup) throws {
        func ids<T: Identifiable>(_ rows: [T], _ name: String) throws -> Set<T.ID> {
            let result = Set(rows.map(\.id))
            guard result.count == rows.count else { throw BackupError.invalidRestore(String(localized: "Doppelte IDs: \(name).")) }
            return result
        }
        func require(_ valid: Bool, _ message: String) throws {
            guard valid else { throw BackupError.invalidRestore(message) }
        }
        let accounts = try ids(backup.accounts, String(localized: "Konten"))
        let transactions = try ids(backup.transactions, String(localized: "Buchungen"))
        let categories = try ids(backup.categories, String(localized: "Kategorien"))
        let merchants = try ids(backup.merchants, String(localized: "Händler"))
        let tags = try ids(backup.tags, String(localized: "Tags"))
        let budgets = try ids(backup.budgets, String(localized: "Budgets"))
        let commitments = try ids(backup.recurringCommitments, String(localized: "Fixkosten"))
        let collections = try ids(backup.transactionCollections, String(localized: "Sammlungen"))
        let batches = try ids(backup.importBatches, String(localized: "Importe"))
        let connections = try ids(backup.connections, String(localized: "Verbindungen"))
        _ = try ids(backup.annotations, String(localized: "Anmerkungen"))
        _ = try ids(backup.splitLines, String(localized: "Splits"))
        _ = try ids(backup.recurringOccurrences, String(localized: "Zahlungszuordnungen"))
        _ = try ids(backup.budgetAmountHistory, String(localized: "Budgethistorie"))
        _ = try ids(backup.sharedExpenseShares, String(localized: "Gruppenanteile"))
        _ = try ids(backup.rules, String(localized: "Regeln"))
        _ = try ids(backup.attachments, String(localized: "Belege"))
        _ = try ids(backup.transactionCollectionOverrides, String(localized: "Sammlungszuordnungen"))
        try require(Set(backup.annotations.map(\.transactionID)).count == backup.annotations.count, String(localized: "Mehrere Anmerkungen für dieselbe Buchung."))
        try require(Set(backup.attachments.map(\.localRelativePath)).count == backup.attachments.count, String(localized: "Mehrere Belege mit demselben Dateipfad."))
        for account in backup.accounts {
            try require(account.connectionID.map(connections.contains) ?? true, String(localized: "Konto verweist auf eine fehlende Verbindung."))
        }
        for transaction in backup.transactions {
            try require(accounts.contains(transaction.accountID), String(localized: "Buchung verweist auf ein fehlendes Konto."))
            try require(transaction.categoryID.map(categories.contains) ?? true, String(localized: "Buchung verweist auf eine fehlende Kategorie."))
            try require(transaction.merchantID.map(merchants.contains) ?? true, String(localized: "Händler fehlt. Dieses ältere Backup kann nicht vollständig wiederhergestellt werden."))
            try require(Set(transaction.tagIDs ?? []).isSubset(of: tags), String(localized: "Buchung verweist auf fehlende Tags."))
            try require(transaction.importBatchID.map(batches.contains) ?? true, String(localized: "Importnachweis fehlt."))
        }
        let parents = Dictionary(uniqueKeysWithValues: backup.categories.map { ($0.id, $0.parentID) })
        for category in backup.categories {
            var visited: Set<UUID> = [category.id]
            var parent = category.parentID
            while let id = parent {
                try require(categories.contains(id) && visited.insert(id).inserted, String(localized: "Ungültige Kategoriehierarchie."))
                parent = parents[id] ?? nil
            }
        }
        for annotation in backup.annotations {
            try require(transactions.contains(annotation.transactionID) && Set(annotation.tagIDs ?? []).isSubset(of: tags), String(localized: "Ungültiger Verweis in einer Anmerkung."))
        }
        for line in backup.splitLines {
            try require(transactions.contains(line.parentTransactionID) && (line.categoryID.map(categories.contains) ?? true) && line.amount > 0, String(localized: "Ungültige Splitposition."))
        }
        let transactionByID = Dictionary(uniqueKeysWithValues: backup.transactions.map { ($0.id, $0) })
        for (id, lines) in Dictionary(grouping: backup.splitLines, by: \.parentTransactionID) {
            if let transaction = transactionByID[id] {
                try require(TransactionSplitValidator.validate(lines: lines, parent: transaction) == .valid, String(localized: "Splits ergeben nicht den Buchungsbetrag."))
            }
        }
        for rule in backup.rules { try require(categories.contains(rule.categoryID), String(localized: "Regel verweist auf eine fehlende Kategorie.")) }
        for budget in backup.budgets {
            try require(budget.categoryIDs.isSubset(of: categories) && budget.accountIDs.isSubset(of: accounts) && budget.tagIDs.isSubset(of: tags), String(localized: "Ungültiger Budgetverweis."))
            if case .salaryCycle(let id) = budget.periodPolicy { try require(commitments.contains(id), String(localized: "Gehaltszyklus verweist auf fehlende Einnahmen.")) }
        }
        for history in backup.budgetAmountHistory { try require(budgets.contains(history.budgetID), String(localized: "Budgethistorie ohne Budget.")) }
        for commitment in backup.recurringCommitments {
            try require(commitment.categoryID.map(categories.contains) ?? true, String(localized: "Fixkostenkategorie fehlt."))
            try require(commitment.matchingAccountID.map(accounts.contains) ?? true, String(localized: "Fixkostenkonto fehlt."))
        }
        for occurrence in backup.recurringOccurrences { try require(commitments.contains(occurrence.commitmentID) && transactions.contains(occurrence.transactionID), String(localized: "Ungültige Zahlungszuordnung.")) }
        for collection in backup.transactionCollections { try require(collection.accountIDs.isSubset(of: accounts), String(localized: "Sammlung verweist auf fehlende Konten.")) }
        for override in backup.transactionCollectionOverrides { try require(collections.contains(override.collectionID) && transactions.contains(override.transactionID), String(localized: "Ungültige Sammlungszuordnung.")) }
        for attachment in backup.attachments { try require(transactions.contains(attachment.transactionID), String(localized: "Beleg ohne Buchung.")); try validatePath(attachment.localRelativePath) }
        for share in backup.sharedExpenseShares { try require(transactions.contains(share.transactionID), String(localized: "Gruppenanteil ohne Buchung.")) }
    }

    func replace(with prepared: PreparedBackupRestore, attachmentsDirectory: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        let generationName = "restored-\(UUID().uuidString)"
        let generation = attachmentsDirectory.appendingPathComponent(generationName, isDirectory: true)
        try fm.createDirectory(at: generation, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: generation) } }
        for file in prepared.files {
            let url = generation.appendingPathComponent(file.relativePath)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url, options: .atomic)
        }
        var backup = prepared.backup
        backup.attachments = backup.attachments.map { attachment in
            var mapped = attachment
            mapped.localRelativePath = "\(generationName)/\(attachment.localRelativePath)"
            return mapped
        }
        try await persistence.replaceBackupAtomically(backup)
        committed = true
    }
}
