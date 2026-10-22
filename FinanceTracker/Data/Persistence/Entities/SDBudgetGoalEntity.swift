import Foundation
import SwiftData

/// P2 Sparziele (Sinking-Fund-Zielmarke): 1:1-Sidecar zu `SDBudget2Entity`
/// (V11, additiv: bestehende Entities bleiben hash-stabil, vgl.
/// SDBudget2Entity-Doku). Domain-seitig KEIN Parallelmodell (#11/#30):
/// Die Zeile wird immer in `Budget.targetAmount/targetDate` gemappt.
///
/// Nur Budgets MIT Ziel haben eine Zeile (nil-Ziel = keine Zeile).
/// Währung ist immer die Budget-Währung (#19/#35).
@Model
final class SDBudgetGoalEntity {
    @Attribute(.unique) var budgetID: UUID
    /// Zielbetrag als Dezimal-String (nil = nur Datum gesetzt).
    var targetAmountValue: String?
    var targetDate: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        budgetID: UUID,
        targetAmountValue: String?,
        targetDate: Date?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.budgetID = budgetID
        self.targetAmountValue = targetAmountValue
        self.targetDate = targetDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension SDBudgetGoalEntity {
    convenience init(budgetID: UUID, targetAmount: Decimal?, targetDate: Date?) {
        self.init(
            budgetID: budgetID,
            targetAmountValue: targetAmount.map { NSDecimalNumber(decimal: $0).stringValue },
            targetDate: targetDate,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func update(targetAmount: Decimal?, targetDate: Date?) {
        targetAmountValue = targetAmount.map { NSDecimalNumber(decimal: $0).stringValue }
        self.targetDate = targetDate
        updatedAt = Date()
    }

    /// Strikte Auflösung (#23): korrupte Beträge nie als 0 maskieren.
    func targetAmount() throws -> Decimal? {
        guard let raw = targetAmountValue else { return nil }
        guard let parsed = Decimal(string: raw) else {
            throw PersistenceDecodingError.invalidAmount(field: "budgetTargetAmount", raw: raw)
        }
        return parsed
    }
}
