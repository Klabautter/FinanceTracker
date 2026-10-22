import Foundation
import SwiftData

@Model
final class SDBudgetAmountHistoryEntity {
    @Attribute(.unique) var id: UUID
    var budgetID: UUID
    var periodStart: Date
    var amountValue: String
    var currencyRaw: String
    var createdAt: Date

    init(id: UUID, budgetID: UUID, periodStart: Date, amountValue: String, currencyRaw: String, createdAt: Date) {
        self.id = id
        self.budgetID = budgetID
        self.periodStart = periodStart
        self.amountValue = amountValue
        self.currencyRaw = currencyRaw
        self.createdAt = createdAt
    }
}

extension SDBudgetAmountHistoryEntity {
    convenience init(from history: BudgetAmountHistory) {
        self.init(
            id: history.id,
            budgetID: history.budgetID,
            periodStart: history.periodStart,
            amountValue: NSDecimalNumber(decimal: history.amount).stringValue,
            currencyRaw: history.currency.rawValue,
            createdAt: Date()
        )
    }

    func toDomain() throws -> BudgetAmountHistory {
        guard let amount = Decimal(string: amountValue) else {
            throw PersistenceDecodingError.invalidAmount(field: "historyAmount", raw: amountValue)
        }
        return BudgetAmountHistory(
            id: id,
            budgetID: budgetID,
            periodStart: periodStart,
            amount: amount,
            currency: CurrencyCode(currencyRaw)
        )
    }
}
