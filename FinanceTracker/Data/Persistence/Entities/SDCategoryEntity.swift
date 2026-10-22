import Foundation
import SwiftData

@Model
final class SDCategoryEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var systemIconName: String
    var colorTokenRaw: String?
    var parentID: UUID?

    init(id: UUID, name: String, systemIconName: String, colorTokenRaw: String?, parentID: UUID?) {
        self.id = id
        self.name = name
        self.systemIconName = systemIconName
        self.colorTokenRaw = colorTokenRaw
        self.parentID = parentID
    }
}
