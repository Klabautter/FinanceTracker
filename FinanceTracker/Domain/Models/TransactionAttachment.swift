import Foundation

/// Transaction-Attachment (Roadmap #143–144): Metadaten in SwiftData,
/// Dateiinhalte unter Application Support (nie als Blob, #145/#242-33).
struct TransactionAttachment: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let transactionID: UUID
    var fileName: String
    var mimeType: String
    /// Relativer Pfad unter dem Attachments-Verzeichnis der App.
    var localRelativePath: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        transactionID: UUID,
        fileName: String,
        mimeType: String,
        localRelativePath: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.transactionID = transactionID
        self.fileName = fileName
        self.mimeType = mimeType
        self.localRelativePath = localRelativePath
        self.createdAt = createdAt
    }
}
