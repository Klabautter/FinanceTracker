import Foundation
import SwiftData

@Model
final class SDTransactionCollectionEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var systemIconName: String
    var startDate: Date
    var endDateExclusive: Date
    var accountIDsJSON: Data
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        systemIconName: String,
        startDate: Date,
        endDateExclusive: Date,
        accountIDsJSON: Data,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.systemIconName = systemIconName
        self.startDate = startDate
        self.endDateExclusive = endDateExclusive
        self.accountIDsJSON = accountIDsJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
