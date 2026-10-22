import Foundation
import SwiftData

@Model
final class SDTransactionSplitLineEntity {
    @Attribute(.unique) var id: UUID
    var parentTransactionID: UUID
    var amountValue: String
    var categoryID: UUID?
    var note: String?
    var createdAt: Date

    init(
        id: UUID,
        parentTransactionID: UUID,
        amountValue: String,
        categoryID: UUID?,
        note: String?,
        createdAt: Date
    ) {
        self.id = id
        self.parentTransactionID = parentTransactionID
        self.amountValue = amountValue
        self.categoryID = categoryID
        self.note = note
        self.createdAt = createdAt
    }
}

extension SDTransactionSplitLineEntity {
    convenience init(from line: TransactionSplitLine) {
        self.init(
            id: line.id,
            parentTransactionID: line.parentTransactionID,
            amountValue: NSDecimalNumber(decimal: line.amount).stringValue,
            categoryID: line.categoryID,
            note: line.note,
            createdAt: Date()
        )
    }

    func update(from line: TransactionSplitLine) {
        amountValue = NSDecimalNumber(decimal: line.amount).stringValue
        categoryID = line.categoryID
        note = line.note
    }

    func toDomain() throws -> TransactionSplitLine {
        guard let amount = Decimal(string: amountValue) else {
            throw PersistenceDecodingError.invalidAmount(field: "splitAmount", raw: amountValue)
        }
        return TransactionSplitLine(
            id: id,
            parentTransactionID: parentTransactionID,
            amount: amount,
            categoryID: categoryID,
            note: note
        )
    }
}
