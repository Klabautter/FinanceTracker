import Foundation
import SwiftData

@Model
final class SDTransactionAttachmentEntity {
    @Attribute(.unique) var id: UUID
    var transactionID: UUID
    var fileName: String
    var mimeType: String
    var localRelativePath: String
    var createdAt: Date

    init(
        id: UUID,
        transactionID: UUID,
        fileName: String,
        mimeType: String,
        localRelativePath: String,
        createdAt: Date
    ) {
        self.id = id
        self.transactionID = transactionID
        self.fileName = fileName
        self.mimeType = mimeType
        self.localRelativePath = localRelativePath
        self.createdAt = createdAt
    }
}

extension SDTransactionAttachmentEntity {
    func toDomain() -> TransactionAttachment {
        TransactionAttachment(
            id: id,
            transactionID: transactionID,
            fileName: fileName,
            mimeType: mimeType,
            localRelativePath: localRelativePath,
            createdAt: createdAt
        )
    }
}
