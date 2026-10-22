import Foundation

struct TransactionAnnotation: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let transactionID: UUID
    var note: String?
    var reviewed: Bool
    var excludedFromAnalytics: Bool
    var manualKindOverride: TransactionKind?
    var tagIDs: [UUID]?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        transactionID: UUID,
        note: String? = nil,
        reviewed: Bool = false,
        excludedFromAnalytics: Bool = false,
        manualKindOverride: TransactionKind? = nil,
        tagIDs: [UUID]? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.transactionID = transactionID
        self.note = note
        self.reviewed = reviewed
        self.excludedFromAnalytics = excludedFromAnalytics
        self.manualKindOverride = manualKindOverride
        self.tagIDs = tagIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension TransactionAnnotation {
    static func legacyFallback(for transaction: Transaction) -> TransactionAnnotation {
        TransactionAnnotation(
            transactionID: transaction.id,
            note: transaction.note,
            reviewed: transaction.reviewed,
            excludedFromAnalytics: transaction.excludedFromAnalytics,
            tagIDs: transaction.tagIDs,
            createdAt: transaction.createdAt,
            updatedAt: transaction.updatedAt
        )
    }
}
