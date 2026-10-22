import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Vollständiges Backup (Roadmap #151–153 / WP29): versioniert, ohne
/// Secrets. Die Wiederherstellung übernimmt BackupRestoreService.
///
/// P2 Gruppenanteile (#27/#34): `sharedExpenseShares` ist ein optionales
/// Feld-Append auf V4, kein Versionsbump nötig, V4-Dateien ohne den Key
/// bleiben lesbar (`decodeIfPresent` → []). Anteile enthalten nur
/// Nutzer-Labels/Beträge, keine Secrets (#34).
struct FinanceTrackerBackup: Codable, Sendable {
    /// V4: P2 Sparziele (Budget.targetAmount/targetDate). V3: Transaction
    /// Collections + Overrides. V4+Shares: optionales
    /// `sharedExpenseShares`-Feld (kein Bump: abwärtskompatibel).
    static let formatVersion = 4

    let formatVersion: Int
    let exportedAt: Date

    let accounts: [Account]
    let transactions: [Transaction]
    let annotations: [TransactionAnnotation]
    let transactionCollections: [TransactionCollection]
    let transactionCollectionOverrides: [TransactionCollectionOverride]
    let categories: [Category]
    let merchants: [Merchant]
    let rules: [CategoryRule]
    let tags: [Tag]
    let budgets: [Budget]
    let budgetAmountHistory: [BudgetAmountHistory]
    let recurringCommitments: [RecurringCommitment]
    let recurringOccurrences: [RecurringOccurrence]
    let splitLines: [TransactionSplitLine]
    let importBatches: [ImportBatch]
    /// P2 Gruppenanteile (User-Sidecar, #27): je Transaktion N Zeilen.
    /// Optionaler Key (V4-Append): fehlt er, gilt [].
    let sharedExpenseShares: [SharedExpenseShare]
    /// Attachment-Metadaten (Dateiinhalte liegen im Package unter attachments/).
    var attachments: [TransactionAttachment]
    /// Connections nur als Metadaten (ohne Secrets: die liegen in der
    /// Keychain, Roadmap #151/#186).
    let connections: [Connection]

    init(
        formatVersion: Int,
        exportedAt: Date,
        accounts: [Account],
        transactions: [Transaction],
        annotations: [TransactionAnnotation],
        transactionCollections: [TransactionCollection],
        transactionCollectionOverrides: [TransactionCollectionOverride],
        categories: [Category],
        rules: [CategoryRule],
        tags: [Tag],
        budgets: [Budget],
        budgetAmountHistory: [BudgetAmountHistory],
        recurringCommitments: [RecurringCommitment],
        recurringOccurrences: [RecurringOccurrence],
        splitLines: [TransactionSplitLine],
        importBatches: [ImportBatch],
        sharedExpenseShares: [SharedExpenseShare] = [],
        attachments: [TransactionAttachment],
        connections: [Connection],
        merchants: [Merchant] = []
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.accounts = accounts
        self.transactions = transactions
        self.annotations = annotations
        self.transactionCollections = transactionCollections
        self.transactionCollectionOverrides = transactionCollectionOverrides
        self.categories = categories
        self.merchants = merchants
        self.rules = rules
        self.tags = tags
        self.budgets = budgets
        self.budgetAmountHistory = budgetAmountHistory
        self.recurringCommitments = recurringCommitments
        self.recurringOccurrences = recurringOccurrences
        self.splitLines = splitLines
        self.importBatches = importBatches
        self.sharedExpenseShares = sharedExpenseShares
        self.attachments = attachments
        self.connections = connections
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard (1...Self.formatVersion).contains(sourceVersion) else {
            throw BackupError.unsupportedFormatVersion(sourceVersion)
        }

        formatVersion = Self.formatVersion
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        accounts = try container.decode([Account].self, forKey: .accounts)
        transactions = try container.decode([Transaction].self, forKey: .transactions)
        annotations = try container.decode([TransactionAnnotation].self, forKey: .annotations)
        categories = try container.decode([Category].self, forKey: .categories)
        merchants = try container.decodeIfPresent([Merchant].self, forKey: .merchants) ?? []
        rules = try container.decode([CategoryRule].self, forKey: .rules)
        tags = try container.decode([Tag].self, forKey: .tags)
        budgets = try container.decode([Budget].self, forKey: .budgets)
        budgetAmountHistory = try container.decode([BudgetAmountHistory].self, forKey: .budgetAmountHistory)
        recurringCommitments = try container.decode([RecurringCommitment].self, forKey: .recurringCommitments)
        splitLines = try container.decode([TransactionSplitLine].self, forKey: .splitLines)
        importBatches = try container.decode([ImportBatch].self, forKey: .importBatches)
        connections = try container.decode([Connection].self, forKey: .connections)

        if sourceVersion >= 2 {
            recurringOccurrences = try container.decode([RecurringOccurrence].self, forKey: .recurringOccurrences)
            attachments = try container.decode([TransactionAttachment].self, forKey: .attachments)
        } else {
            recurringOccurrences = try container.decodeIfPresent(
                [RecurringOccurrence].self,
                forKey: .recurringOccurrences
            ) ?? []
            attachments = try container.decodeIfPresent(
                [TransactionAttachment].self,
                forKey: .attachments
            ) ?? []
        }

        if sourceVersion >= 3 {
            transactionCollections = try container.decode(
                [TransactionCollection].self,
                forKey: .transactionCollections
            )
            transactionCollectionOverrides = try container.decode(
                [TransactionCollectionOverride].self,
                forKey: .transactionCollectionOverrides
            )
        } else {
            transactionCollections = []
            transactionCollectionOverrides = []
        }

        // P2-Append (#34): optionale Shares, V4 ohne Key liest als [].
        // Korrupte Shares werden NICHT maskiert (#23): vorhandene, aber
        // unparsebare Einträge werfen statt still [] zu liefern.
        sharedExpenseShares = try container.decodeIfPresent(
            [SharedExpenseShare].self,
            forKey: .sharedExpenseShares
        ) ?? []
    }
}

/// WP29: Ein Attachment-Inhalt im Backup-Package.
struct BackupAttachmentFile: Sendable {
    let relativePath: String
    let data: Data
}

enum BackupError: Error, Equatable, LocalizedError {
    case encodingFailed(String)
    case invalidRestore(String)
    case unsupportedFormatVersion(Int)
    case attachmentFileMissing(String)
    /// WP17 (§123): Gesamtgröße der Belege überschreitet die Policy-Grenze,
    /// kontrollierter Fehler statt OOM-Risiko.
    case attachmentBudgetExceeded(totalBytes: Int, limitBytes: Int)
    case orphanedCollectionOverride(collectionID: UUID)
    case orphanedTransactionOverride(transactionID: UUID)
    var errorDescription: String? {
        switch self {
        case .encodingFailed(let reason), .invalidRestore(let reason): reason
        case .unsupportedFormatVersion(let version): String(localized: "Backup-Version \(version) wird nicht unterstützt.")
        case .attachmentFileMissing(let path): String(localized: "Belegdatei fehlt: \(path).")
        case .attachmentBudgetExceeded(let bytes, let limit): String(localized: "Belege sind zu groß (\(bytes / 1024 / 1024) MB; Grenze \(limit / 1024 / 1024) MB).")
        case .orphanedCollectionOverride: String(localized: "Sammlungszuordnung ohne zugehörige Sammlung.")
        case .orphanedTransactionOverride: String(localized: "Sammlungszuordnung ohne zugehörige Buchung.")
        }
    }

}

/// WP30: Backup-Aufbau läuft OFF-MAIN (Repository-Loads sind actor-
/// gekapselt, Encoding/Package-Bau detached). MainActor sieht nur den
/// UI-Progress.
///
/// P2 Streaming: Transaktionen werden batched über `transactionPage`
/// geladen (DB-Paging statt Voll-Hydration). Domain-API unverändert:
/// nur der Export-Pfad nutzt Paging. Kleine Tabellen laden weiter direkt.
enum BackupService {
    /// Batch-Größe für den Transaktions-Paging-Pfad.
    static let transactionPageSize = 1000

    nonisolated static func makeBackup(dependencies: AppDependencies) async throws -> FinanceTrackerBackup {
        async let accountsTask = dependencies.accountRepository.accounts()
        async let annotationsTask = dependencies.transactionAnnotationRepository.annotations()
        async let collectionsTask = dependencies.transactionCollectionRepository.collections()
        async let overridesTask = dependencies.transactionCollectionOverrideRepository.allOverrides()
        async let categoriesTask = dependencies.categoryRepository.categories()
        async let merchantsTask = dependencies.merchantRepository.merchants()
        async let rulesTask = dependencies.ruleRepository.rules()
        async let tagsTask = dependencies.tagRepository.tags()
        async let budgetsTask = dependencies.budgetRepository.budgets()
        async let historyTask = dependencies.budgetRepository.amountHistory(budgetID: nil)
        async let commitmentsTask = dependencies.recurringCommitmentRepository.commitments()
        async let occurrencesTask = dependencies.recurringCommitmentRepository.allOccurrences()
        async let splitLinesTask = dependencies.transactionSplitRepository.allSplitLines()
        async let sharesTask = dependencies.sharedExpenseShareRepository.allShares()
        async let batchesTask = dependencies.importBatchRepository.batches()
        async let connectionsTask = dependencies.connectionRepository.connections()
        async let attachmentsTask = dependencies.transactionAttachmentRepository.allAttachments()

        // Batched Transaktions-Load (kein loadAllTransactions).
        let transactions = try await pagedAllTransactions(
            repository: dependencies.transactionRepository
        )

        return FinanceTrackerBackup(
            formatVersion: FinanceTrackerBackup.formatVersion,
            exportedAt: Date(),
            accounts: try await accountsTask,
            transactions: transactions,
            annotations: try await annotationsTask,
            transactionCollections: try await collectionsTask,
            transactionCollectionOverrides: try await overridesTask,
            categories: try await categoriesTask,
            rules: try await rulesTask,
            tags: try await tagsTask,
            budgets: try await budgetsTask,
            budgetAmountHistory: try await historyTask,
            recurringCommitments: try await commitmentsTask,
            recurringOccurrences: try await occurrencesTask,
            splitLines: try await splitLinesTask,
            importBatches: try await batchesTask,
            sharedExpenseShares: try await sharesTask,
            attachments: try await attachmentsTask,
            connections: try await connectionsTask,
            merchants: try await merchantsTask
        )
    }

    /// Batched Voll-Load über existierendes Paging (fetchOffset/fetchLimit).
    /// Reihenfolge: Store-Sortierung (dateDescending); für das Backup
    /// irrelevant (Decode bewahrt keine Ordnungsgarantie), Vollständigkeit
    /// zählt. Kein API-Bruch: nutzt nur die bestehende Domain-Methode.
    nonisolated static func pagedAllTransactions(
        repository: any TransactionRepository,
        pageSize: Int = BackupService.transactionPageSize
    ) async throws -> [Transaction] {
        var all: [Transaction] = []
        var offset = 0
        while true {
            let page = try await repository.transactionPage(
                matching: TransactionQuery(),
                sort: .dateDescending,
                offset: offset,
                limit: pageSize
            )
            all.append(contentsOf: page.transactions)
            if !page.hasMore || page.transactions.isEmpty { break }
            offset += page.transactions.count
        }
        return all
    }

    /// WP29 (§201): Vollständiges Backup als `.ftbackup`-Package (ZIP) mit
    /// manifest.json, data.json und den Attachment-Dateien.
    ///
    /// Fehlt eine Attachment-Datei im Dateisystem, schlägt das Backup
    /// kontrolliert fehl (kein stiller Fallback: §17/§18).
    ///
    /// WP17 (§120-124): Memory-Policy:
    /// - `includeAttachments: false` → Datenbackup ohne Belege (klein).
    /// - Mit Belegen wird die GESAMTGRÖSSE vor dem RAM-Load geprüft
    ///   (Default-Limit 500 MB); Überschreitung → kontrollierter Fehler,
    ///   nicht OOM. Der ZIP-Writer bleibt In-Memory, aber begrenzt.
    nonisolated static let maxTotalAttachmentBytesDefault = 500 * 1024 * 1024

    nonisolated static func makeBackupPackage(
        dependencies: AppDependencies,
        appVersion: String = BackupService.appVersion,
        includeAttachments: Bool = true,
        maxTotalAttachmentBytes: Int = BackupService.maxTotalAttachmentBytesDefault,
        attachmentsBaseDirectory: URL? = nil
    ) async throws -> Data {
        let backup = try await makeBackup(dependencies: dependencies)

        guard includeAttachments, !backup.attachments.isEmpty else {
            // Datenbackup ohne Belege: Attachment-Metadaten bleiben in
            // data.json erhalten (vollständige Struktur, nur Inhalte fehlen).
            return try await Task.detached(priority: .userInitiated) {
                try PerfSignpost.measure("BackupExport") {
                    try package(backup: backup, attachmentFiles: [], appVersion: appVersion)
                }
            }.value
        }

        // WP30: Datei-IO off-main, Attachment-Bytes parallel lesen; eine
        // fehlende Datei schlägt kontrolliert fehl (§17/§18).
        let baseDirectory = try attachmentsBaseDirectory ?? AttachmentService.defaultBaseDirectory()

        // WP17 (§123): Gesamtgröße VOR dem RAM-Load bestimmen.
        let totalBytes = try await Task.detached(priority: .userInitiated) {
            try Self.totalAttachmentBytes(
                attachments: backup.attachments,
                baseDirectory: baseDirectory
            )
        }.value
        guard totalBytes <= maxTotalAttachmentBytes else {
            throw BackupError.attachmentBudgetExceeded(
                totalBytes: totalBytes,
                limitBytes: maxTotalAttachmentBytes
            )
        }

        let attachmentFiles: [BackupAttachmentFile] = try await Task.detached(priority: .userInitiated) {
            let service = AttachmentService(attachmentsBaseDirectory: baseDirectory)
            return try backup.attachments.map { attachment in
                // WP30: IO-Fehler werden auf den kontrollierten Domain-Fehler
                // gemappt (§17/§18, nicht still schlucken, nicht durchlassen).
                let data: Data
                do {
                    data = try service.data(forRelativePath: attachment.localRelativePath)
                } catch {
                    throw BackupError.attachmentFileMissing(attachment.localRelativePath)
                }
                guard !data.isEmpty else {
                    throw BackupError.attachmentFileMissing(attachment.localRelativePath)
                }
                return BackupAttachmentFile(relativePath: attachment.localRelativePath, data: data)
            }
        }.value

        return try await Task.detached(priority: .userInitiated) {
            try PerfSignpost.measure("BackupExport") {
                try package(backup: backup, attachmentFiles: attachmentFiles, appVersion: appVersion)
            }
        }.value
    }

    /// WP17 (§123): Gesamtgröße der Attachment-Dateien (Dateisystem-Attribute,
    /// kein RAM-Load).
    nonisolated static func totalAttachmentBytes(
        attachments: [TransactionAttachment],
        baseDirectory: URL
    ) throws -> Int {
        let service = AttachmentService(attachmentsBaseDirectory: baseDirectory)
        var total = 0
        for attachment in attachments {
            let url = service.absoluteURL(forRelativePath: attachment.localRelativePath)
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.fileSizeKey])
            } catch {
                // Fehlende/unlesbare Datei → kontrollierter Domain-Fehler.
                throw BackupError.attachmentFileMissing(attachment.localRelativePath)
            }
            guard let size = values.fileSize, size > 0 else {
                throw BackupError.attachmentFileMissing(attachment.localRelativePath)
            }
            total += size
        }
        return total
    }

    nonisolated static func package(
        backup: FinanceTrackerBackup,
        attachmentFiles: [BackupAttachmentFile],
        appVersion: String
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let dataJSON = try encoder.encode(backup)

        struct Manifest: Codable {
            let formatVersion: Int
            let appVersion: String
            let exportedAt: Date
            let attachmentCount: Int
        }
        let manifest = Manifest(
            formatVersion: FinanceTrackerBackup.formatVersion,
            appVersion: appVersion,
            exportedAt: backup.exportedAt,
            attachmentCount: attachmentFiles.count
        )
        let manifestJSON = try encoder.encode(manifest)

        var entries: [BackupArchiveWriter.Entry] = [
            .init(name: "manifest.json", data: manifestJSON),
            .init(name: "data.json", data: dataJSON)
        ]
        for file in attachmentFiles {
            try BackupRestoreService.validatePath(file.relativePath)
            let sanitized = file.relativePath
            entries.append(.init(name: "attachments/\(sanitized)", data: file.data))
        }

        return try BackupArchiveWriter.archive(entries: entries)
    }

    nonisolated static func encode(_ backup: FinanceTrackerBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    nonisolated static func decode(_ data: Data) throws -> FinanceTrackerBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(FinanceTrackerBackup.self, from: data)
        guard backup.formatVersion == FinanceTrackerBackup.formatVersion else {
            throw BackupError.unsupportedFormatVersion(backup.formatVersion)
        }
        return backup
    }

    /// Liest den versionierten Datenbestand aus einem `.ftbackup`-Archiv.
    /// Persistentes Restore bleibt eine separate Orchestrierung; hier werden
    /// Archiv und Datenmodell strikt validiert und ältere Formate migriert.
    nonisolated static func decodePackage(_ data: Data) throws -> FinanceTrackerBackup {
        let archive = try ZipArchiveReader(data: data, maxArchiveBytes: BackupRestoreService.maxArchiveBytes, maxEntryBytes: BackupRestoreService.maxArchiveBytes, verifyChecksums: true)
        return try decode(archive.extractEntry("data.json"))
    }

    /// Importiert ausschließlich Transaction Collections und Overrides als
    /// Merge. Ein vollständiges Backup-Restore bleibt eine eigene Operation.
    nonisolated static func importTransactionCollections(
        from backup: FinanceTrackerBackup,
        dependencies: AppDependencies
    ) async throws {
        let collectionIDs = Set(backup.transactionCollections.map(\.id))
        let transactionIDs = Set(backup.transactions.map(\.id))
        for override in backup.transactionCollectionOverrides {
            guard collectionIDs.contains(override.collectionID) else {
                throw BackupError.orphanedCollectionOverride(collectionID: override.collectionID)
            }
            guard transactionIDs.contains(override.transactionID) else {
                throw BackupError.orphanedTransactionOverride(transactionID: override.transactionID)
            }
        }

        try await dependencies.transactionCollectionRepository.upsert(backup.transactionCollections)
        try await dependencies.transactionCollectionOverrideRepository.upsert(
            backup.transactionCollectionOverrides
        )
    }

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }
}

/// WP29: FileDocument für den `.ftbackup`-Export.
struct BackupPackageDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.init(exportedAs: "de.klabautter.ftbackup")]
    }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
