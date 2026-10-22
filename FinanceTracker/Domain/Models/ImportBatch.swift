import CryptoKit
import Foundation

struct ImportBatch: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var providerIdentifier: String
    var sourceRaw: String
    var fileName: String?
    var fileHashSHA256: String
    var startedAt: Date
    var completedAt: Date
    var totalRows: Int
    var importedCount: Int
    var updatedCount: Int
    var duplicateCount: Int
    var failedCount: Int
    var mutations: [ImportMutation]

    init(
        id: UUID = UUID(),
        providerIdentifier: String,
        sourceRaw: String,
        fileName: String?,
        fileHashSHA256: String,
        startedAt: Date,
        completedAt: Date,
        totalRows: Int,
        importedCount: Int,
        updatedCount: Int,
        duplicateCount: Int,
        failedCount: Int,
        mutations: [ImportMutation] = []
    ) {
        self.id = id
        self.providerIdentifier = providerIdentifier
        self.sourceRaw = sourceRaw
        self.fileName = fileName
        self.fileHashSHA256 = fileHashSHA256
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.totalRows = totalRows
        self.importedCount = importedCount
        self.updatedCount = updatedCount
        self.duplicateCount = duplicateCount
        self.failedCount = failedCount
        self.mutations = mutations
    }
}

protocol ImportBatchRepository: Sendable {
    func batches() async throws -> [ImportBatch]
    func latestBatch() async throws -> ImportBatch?
    func batch(id: UUID) async throws -> ImportBatch?
    func upsert(_ batches: [ImportBatch]) async throws
    func delete(id: UUID) async throws
    /// WP2 (§14): Alle Import-Batches entfernen.
    func deleteAll() async throws
    func commitImport(batch: ImportBatch, inserts: [Transaction], updates: [Transaction]) async throws
    func rollbackImportBatch(id: UUID) async throws
}

extension ImportBatch {
    static func fileHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
