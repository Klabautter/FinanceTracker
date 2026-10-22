import Foundation
import SwiftData

@Model
final class SDTagEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorTokenRaw: String

    init(id: UUID, name: String, colorTokenRaw: String) {
        self.id = id
        self.name = name
        self.colorTokenRaw = colorTokenRaw
    }
}

extension SDTagEntity {
    convenience init(from tag: Tag) {
        self.init(id: tag.id, name: tag.name, colorTokenRaw: tag.colorToken.rawValue)
    }

    func update(from tag: Tag) {
        name = tag.name
        colorTokenRaw = tag.colorToken.rawValue
    }

    func toDomain() -> Tag {
        Tag(id: id, name: name, colorToken: TagColorToken(rawValue: colorTokenRaw) ?? .blue)
    }
}
