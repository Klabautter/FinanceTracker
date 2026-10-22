import Foundation
import SwiftData

@Model
final class SDMerchantEntity {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var aliases: [String]

    init(id: UUID, displayName: String, aliases: [String]) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
    }
}
