import Foundation
import SwiftData

@Model
final class SDTransactionAnnotationEntity {
    @Attribute(.unique) var transactionID: UUID
    var id: UUID
    var note: String?
    var reviewed: Bool
    var excludedFromAnalytics: Bool
    var manualKindOverrideRaw: String?
    var tagIDsJSON: Data?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        transactionID: UUID,
        note: String?,
        reviewed: Bool,
        excludedFromAnalytics: Bool,
        manualKindOverrideRaw: String?,
        tagIDsJSON: Data?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.transactionID = transactionID
        self.note = note
        self.reviewed = reviewed
        self.excludedFromAnalytics = excludedFromAnalytics
        self.manualKindOverrideRaw = manualKindOverrideRaw
        self.tagIDsJSON = tagIDsJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
