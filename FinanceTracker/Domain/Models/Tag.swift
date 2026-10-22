import Foundation

enum TagColorToken: String, Codable, Sendable, CaseIterable {
    case blue, green, orange, purple, red, teal, yellow, indigo, gray
}

struct Tag: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var colorToken: TagColorToken

    init(id: UUID = UUID(), name: String, colorToken: TagColorToken = .blue) {
        self.id = id
        self.name = name
        self.colorToken = colorToken
    }
}
