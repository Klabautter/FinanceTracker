import Foundation
import SwiftData

/// Budget 2.0 Persistenz (Roadmap #96–99, Milestone F).
/// Bewusst eine NEUE Klasse (statt SDBudgetEntity zu modifizieren):
/// Nur der Budget-Teil wechselt beim Store-Upgrade den Hash: alle anderen
/// Entities bleiben hash-stabil, damit bestehende Stores sauber migrieren.
@Model
final class SDBudget2Entity {
    @Attribute(.unique) var id: UUID
    var name: String
    var systemIconName: String
    var amountValue: String
    var currencyRaw: String
    var periodPolicyRaw: String          // "calendarMonth" | "salaryCycle"
    var startDay: Int                    // calendarMonth(startDay:)
    var salaryIncomeID: UUID?            // salaryCycle(...)
    var categoryIDsJSON: Data            // [UUID]
    var tagIDsJSON: Data?                // [UUID]
    var accountIDsJSON: Data?            // [UUID]
    var rolloverRaw: String              // BudgetRolloverPolicy
    var includeInForecast: Bool
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        systemIconName: String,
        amountValue: String,
        currencyRaw: String,
        periodPolicyRaw: String,
        startDay: Int,
        salaryIncomeID: UUID?,
        categoryIDsJSON: Data,
        tagIDsJSON: Data?,
        accountIDsJSON: Data?,
        rolloverRaw: String,
        includeInForecast: Bool,
        enabled: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.systemIconName = systemIconName
        self.amountValue = amountValue
        self.currencyRaw = currencyRaw
        self.periodPolicyRaw = periodPolicyRaw
        self.startDay = startDay
        self.salaryIncomeID = salaryIncomeID
        self.categoryIDsJSON = categoryIDsJSON
        self.tagIDsJSON = tagIDsJSON
        self.accountIDsJSON = accountIDsJSON
        self.rolloverRaw = rolloverRaw
        self.includeInForecast = includeInForecast
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension SDBudget2Entity {
    convenience init(from budget: Budget) {
        self.init(
            id: budget.id,
            name: budget.name,
            systemIconName: budget.systemIconName,
            amountValue: NSDecimalNumber(decimal: budget.amount).stringValue,
            currencyRaw: budget.currency.rawValue,
            periodPolicyRaw: budget.periodPolicy.storageKey,
            startDay: budget.periodPolicy.startDay ?? 1,
            salaryIncomeID: budget.periodPolicy.salaryIncomeID,
            categoryIDsJSON: JSONCoding.encodeUUIDs(budget.categoryIDs),
            tagIDsJSON: budget.tagIDs.isEmpty ? nil : JSONCoding.encodeUUIDs(budget.tagIDs),
            accountIDsJSON: budget.accountIDs.isEmpty ? nil : JSONCoding.encodeUUIDs(budget.accountIDs),
            rolloverRaw: budget.rolloverPolicy.rawValue,
            includeInForecast: budget.includeInForecast,
            enabled: budget.enabled,
            createdAt: budget.createdAt ?? Date(),
            updatedAt: Date()
        )
    }

    func update(from budget: Budget) {
        name = budget.name
        systemIconName = budget.systemIconName
        amountValue = NSDecimalNumber(decimal: budget.amount).stringValue
        currencyRaw = budget.currency.rawValue
        periodPolicyRaw = budget.periodPolicy.storageKey
        startDay = budget.periodPolicy.startDay ?? 1
        salaryIncomeID = budget.periodPolicy.salaryIncomeID
        categoryIDsJSON = JSONCoding.encodeUUIDs(budget.categoryIDs)
        tagIDsJSON = budget.tagIDs.isEmpty ? nil : JSONCoding.encodeUUIDs(budget.tagIDs)
        accountIDsJSON = budget.accountIDs.isEmpty ? nil : JSONCoding.encodeUUIDs(budget.accountIDs)
        rolloverRaw = budget.rolloverPolicy.rawValue
        includeInForecast = budget.includeInForecast
        enabled = budget.enabled
        updatedAt = Date()
    }

    func toDomain() throws -> Budget {
        guard let amount = Decimal(string: amountValue) else {
            throw PersistenceDecodingError.invalidAmount(field: "budgetAmount", raw: amountValue)
        }
        let period: BudgetPeriodPolicy
        if periodPolicyRaw == "salaryCycle", let salaryIncomeID {
            period = .salaryCycle(recurringIncomeID: salaryIncomeID)
        } else {
            period = .calendarMonth(startDay: max(1, min(28, startDay)))
        }

        return Budget(
            id: id,
            name: name,
            systemIconName: systemIconName,
            amount: amount,
            currency: CurrencyCode(currencyRaw),
            periodPolicy: period,
            categoryIDs: Set(JSONCoding.decodeUUIDs(categoryIDsJSON) ?? []),
            tagIDs: Set(JSONCoding.decodeUUIDs(tagIDsJSON) ?? []),
            accountIDs: Set(JSONCoding.decodeUUIDs(accountIDsJSON) ?? []),
            rolloverPolicy: BudgetRolloverPolicy(rawValue: rolloverRaw) ?? .reset,
            includeInForecast: includeInForecast,
            enabled: enabled,
            createdAt: createdAt
        )
    }
}

enum JSONCoding {
    static func encodeUUIDs(_ ids: Set<UUID>) -> Data {
        (try? JSONEncoder().encode(Array(ids))) ?? Data("[]".utf8)
    }

    static func encodeUUIDs(_ ids: [UUID]) -> Data {
        (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8)
    }

    static func decodeUUIDs(_ data: Data?) -> [UUID]? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode([UUID].self, from: data)
    }
}

extension BudgetPeriodPolicy {
    var storageKey: String {
        switch self {
        case .calendarMonth: "calendarMonth"
        case .salaryCycle: "salaryCycle"
        }
    }

    var startDay: Int? {
        if case .calendarMonth(let startDay) = self { return startDay }
        return nil
    }

    var salaryIncomeID: UUID? {
        if case .salaryCycle(let id) = self { return id }
        return nil
    }
}
