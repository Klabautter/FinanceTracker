import Foundation

struct Merchant: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var displayName: String
    var aliases: [String]

    init(id: UUID = UUID(), displayName: String, aliases: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
    }
}
