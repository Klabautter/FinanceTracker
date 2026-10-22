import Foundation
import SwiftData

@Model
final class SDRuleEntity {
    @Attribute(.unique) var id: UUID
    var priority: Int
    var conditionTypeRaw: String
    var conditionValue: String
    var categoryID: UUID
    var enabled: Bool
    var originRaw: String?

    init(
        id: UUID,
        priority: Int,
        conditionTypeRaw: String,
        conditionValue: String,
        categoryID: UUID,
        enabled: Bool,
        originRaw: String? = nil
    ) {
        self.id = id
        self.priority = priority
        self.conditionTypeRaw = conditionTypeRaw
        self.conditionValue = conditionValue
        self.categoryID = categoryID
        self.enabled = enabled
        self.originRaw = originRaw
    }
}

extension SDRuleEntity {
    convenience init(from rule: CategoryRule) {
        let (type, value) = Self.encode(rule.condition)
        self.init(
            id: rule.id,
            priority: rule.priority,
            conditionTypeRaw: type,
            conditionValue: value,
            categoryID: rule.categoryID,
            enabled: rule.enabled,
            originRaw: rule.origin.rawValue
        )
    }

    func update(from rule: CategoryRule) {
        let (type, value) = Self.encode(rule.condition)
        priority = rule.priority
        conditionTypeRaw = type
        conditionValue = value
        categoryID = rule.categoryID
        enabled = rule.enabled
        originRaw = rule.origin.rawValue
    }

    func toDomain() throws -> CategoryRule {
        guard let condition = Self.decode(type: conditionTypeRaw, value: conditionValue) else {
            throw PersistenceDecodingError.unknownConditionType(raw: conditionTypeRaw)
        }
        return CategoryRule(
            id: id,
            priority: priority,
            condition: condition,
            categoryID: categoryID,
            enabled: enabled,
            origin: originRaw.flatMap(CategoryRuleOrigin.init(rawValue:)) ?? .system
        )
    }

    private static func encode(_ condition: RuleCondition) -> (String, String) {
        switch condition {
        case .merchantEquals(let value): ("merchant_equals", value)
        case .merchantContains(let value): ("merchant_contains", value)
        case .descriptionContains(let value): ("description_contains", value)
        case .descriptionContainsDebit(let value): ("description_contains_debit", value)
        case .descriptionContainsCredit(let value): ("description_contains_credit", value)
        case .merchantIDEquals(let id): ("merchant_id", id.uuidString)
        }
    }

    private static func decode(type: String, value: String) -> RuleCondition? {
        switch type {
        case "merchant_equals":
            return .merchantEquals(value)
        case "merchant_contains":
            return .merchantContains(value)
        case "description_contains":
            return .descriptionContains(value)
        case "description_contains_debit":
            return .descriptionContainsDebit(value)
        case "description_contains_credit":
            return .descriptionContainsCredit(value)
        case "merchant_id":
            guard let id = UUID(uuidString: value) else { return nil }
            return .merchantIDEquals(id)
        default:
            return nil
        }
    }
}
