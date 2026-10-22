import Foundation
import SwiftData

@Model
final class SDTransactionCollectionOverrideEntity {
    @Attribute(.unique) var compositeKey: String
    var collectionID: UUID
    var transactionID: UUID
    var decisionRaw: String
    var createdAt: Date
    var updatedAt: Date

    init(
        compositeKey: String,
        collectionID: UUID,
        transactionID: UUID,
        decisionRaw: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.compositeKey = compositeKey
        self.collectionID = collectionID
        self.transactionID = transactionID
        self.decisionRaw = decisionRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
