import Foundation
import SwiftData

/// LEGACY (V3): Nur noch für die V3→V4-Migration im Schema enthalten
/// (Roadmap Milestone F). Die Budget-Logik nutzt `SDBudget2Entity`.
@Model
final class SDBudgetEntity {
    @Attribute(.unique) var id: UUID
    var categoryID: UUID
    var monthlyLimitValue: String
    var enabled: Bool

    init(id: UUID, categoryID: UUID, monthlyLimitValue: String, enabled: Bool) {
        self.id = id
        self.categoryID = categoryID
        self.monthlyLimitValue = monthlyLimitValue
        self.enabled = enabled
    }
}
