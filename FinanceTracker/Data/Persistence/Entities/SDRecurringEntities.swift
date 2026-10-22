import Foundation
import SwiftData

@Model
final class SDRecurringCommitmentEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var merchantKey: String?
    var directionRaw: String
    var cadenceRaw: String
    var amountPolicyRaw: String
    var expectedAmountValue: String
    var currencyRaw: String
    var categoryID: UUID?
    var nextExpectedDate: Date?
    var statusRaw: String
    var originRaw: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        merchantKey: String?,
        directionRaw: String,
        cadenceRaw: String,
        amountPolicyRaw: String,
        expectedAmountValue: String,
        currencyRaw: String,
        categoryID: UUID?,
        nextExpectedDate: Date?,
        statusRaw: String,
        originRaw: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.merchantKey = merchantKey
        self.directionRaw = directionRaw
        self.cadenceRaw = cadenceRaw
        self.amountPolicyRaw = amountPolicyRaw
        self.expectedAmountValue = expectedAmountValue
        self.currencyRaw = currencyRaw
        self.categoryID = categoryID
        self.nextExpectedDate = nextExpectedDate
        self.statusRaw = statusRaw
        self.originRaw = originRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension SDRecurringCommitmentEntity {
    convenience init(from commitment: RecurringCommitment) {
        self.init(
            id: commitment.id,
            name: commitment.name,
            merchantKey: commitment.merchantKey,
            directionRaw: commitment.direction.rawValue,
            cadenceRaw: commitment.cadence.rawValue,
            amountPolicyRaw: commitment.amountPolicy.rawValue,
            expectedAmountValue: NSDecimalNumber(decimal: commitment.expectedAmount).stringValue,
            currencyRaw: commitment.currency.rawValue,
            categoryID: commitment.categoryID,
            nextExpectedDate: commitment.nextExpectedDate,
            statusRaw: commitment.status.rawValue,
            originRaw: commitment.origin.rawValue,
            createdAt: commitment.createdAt,
            updatedAt: commitment.updatedAt
        )
    }

    func update(from commitment: RecurringCommitment) {
        name = commitment.name
        merchantKey = commitment.merchantKey
        directionRaw = commitment.direction.rawValue
        cadenceRaw = commitment.cadence.rawValue
        amountPolicyRaw = commitment.amountPolicy.rawValue
        expectedAmountValue = NSDecimalNumber(decimal: commitment.expectedAmount).stringValue
        currencyRaw = commitment.currency.rawValue
        categoryID = commitment.categoryID
        nextExpectedDate = commitment.nextExpectedDate
        statusRaw = commitment.status.rawValue
        originRaw = commitment.origin.rawValue
        updatedAt = Date()
    }

    func toDomain() throws -> RecurringCommitment {
        guard let amount = Decimal(string: expectedAmountValue) else {
            throw PersistenceDecodingError.invalidAmount(field: "expectedAmount", raw: expectedAmountValue)
        }
        guard let direction = RecurringCommitment.Direction(rawValue: directionRaw) else {
            throw PersistenceDecodingError.unknownEnum(field: "recurring.direction", raw: directionRaw)
        }
        guard let cadence = RecurringCommitment.Cadence(rawValue: cadenceRaw) else {
            throw PersistenceDecodingError.unknownEnum(field: "recurring.cadence", raw: cadenceRaw)
        }
        guard let amountPolicy = RecurringCommitment.AmountPolicy(rawValue: amountPolicyRaw) else {
            throw PersistenceDecodingError.unknownEnum(field: "recurring.amountPolicy", raw: amountPolicyRaw)
        }
        guard let status = RecurringCommitment.Status(rawValue: statusRaw) else {
            throw PersistenceDecodingError.unknownEnum(field: "recurring.status", raw: statusRaw)
        }
        guard let origin = RecurringCommitment.Origin(rawValue: originRaw) else {
            throw PersistenceDecodingError.unknownEnum(field: "recurring.origin", raw: originRaw)
        }
        return RecurringCommitment(
            id: id,
            name: name,
            merchantKey: merchantKey,
            direction: direction,
            cadence: cadence,
            amountPolicy: amountPolicy,
            expectedAmount: amount,
            currency: CurrencyCode(currencyRaw),
            categoryID: categoryID,
            nextExpectedDate: nextExpectedDate,
            status: status,
            origin: origin,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

@Model
final class SDRecurringOccurrenceEntity {
    @Attribute(.unique) var id: UUID
    var commitmentID: UUID
    var transactionID: UUID
    var createdAt: Date

    init(id: UUID, commitmentID: UUID, transactionID: UUID, createdAt: Date) {
        self.id = id
        self.commitmentID = commitmentID
        self.transactionID = transactionID
        self.createdAt = createdAt
    }
}
