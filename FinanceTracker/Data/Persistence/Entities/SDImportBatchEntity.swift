import Foundation
import SwiftData

@Model
final class SDImportBatchEntity {
    @Attribute(.unique) var id: UUID
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
    var mutationsJSON: Data?

    init(
        id: UUID,
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
        mutationsJSON: Data? = nil
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
        self.mutationsJSON = mutationsJSON
    }
}

extension SDImportBatchEntity {
    convenience init(from batch: ImportBatch) {
        self.init(
            id: batch.id,
            providerIdentifier: batch.providerIdentifier,
            sourceRaw: batch.sourceRaw,
            fileName: batch.fileName,
            fileHashSHA256: batch.fileHashSHA256,
            startedAt: batch.startedAt,
            completedAt: batch.completedAt,
            totalRows: batch.totalRows,
            importedCount: batch.importedCount,
            updatedCount: batch.updatedCount,
            duplicateCount: batch.duplicateCount,
            failedCount: batch.failedCount,
            mutationsJSON: Self.encodeMutations(batch.mutations)
        )
    }

    func update(from batch: ImportBatch) {
        providerIdentifier = batch.providerIdentifier
        sourceRaw = batch.sourceRaw
        fileName = batch.fileName
        fileHashSHA256 = batch.fileHashSHA256
        startedAt = batch.startedAt
        completedAt = batch.completedAt
        totalRows = batch.totalRows
        importedCount = batch.importedCount
        updatedCount = batch.updatedCount
        duplicateCount = batch.duplicateCount
        failedCount = batch.failedCount
        mutationsJSON = Self.encodeMutations(batch.mutations)
    }

    func toDomain() -> ImportBatch {
        ImportBatch(
            id: id,
            providerIdentifier: providerIdentifier,
            sourceRaw: sourceRaw,
            fileName: fileName,
            fileHashSHA256: fileHashSHA256,
            startedAt: startedAt,
            completedAt: completedAt,
            totalRows: totalRows,
            importedCount: importedCount,
            updatedCount: updatedCount,
            duplicateCount: duplicateCount,
            failedCount: failedCount,
            mutations: Self.decodeMutations(mutationsJSON)
        )
    }

    private static func encodeMutations(_ mutations: [ImportMutation]) -> Data? {
        guard !mutations.isEmpty else { return nil }
        return try? JSONEncoder().encode(mutations)
    }

    private static func decodeMutations(_ data: Data?) -> [ImportMutation] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([ImportMutation].self, from: data)) ?? []
    }
}
