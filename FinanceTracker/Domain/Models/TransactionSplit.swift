import Foundation

/// Eine Split-Position einer Transaktion (Roadmap #68).
/// Währung = immer die Währung der Parent-Transaktion.
struct TransactionSplitLine: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let parentTransactionID: UUID
    /// Positiver Betrag in Parent-Währung (Roadmap #69).
    var amount: Decimal
    var categoryID: UUID?
    var note: String?

    init(
        id: UUID = UUID(),
        parentTransactionID: UUID,
        amount: Decimal,
        categoryID: UUID? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.parentTransactionID = parentTransactionID
        self.amount = amount
        self.categoryID = categoryID
        self.note = note
    }
}

enum TransactionSplitValidator {
    /// Roadmap #69: Summe der Split-Beträge muss exakt dem Betrags-Betrag
    /// der Parent-Transaktion entsprechen (Decimal-Arithmetik).
    static func validate(lines: [TransactionSplitLine], parent: Transaction) -> TransactionSplitValidationResult {
        let parentMagnitude = abs(parent.amount.amount)

        for line in lines {
            guard line.amount > 0 else {
                return .invalid(String(localized: "Split-Beträge müssen größer als 0 sein."))
            }
        }

        let sum = lines.reduce(into: Decimal(0)) { partial, line in
            partial += line.amount
        }
        guard sum == parentMagnitude else {
            return .invalid(String(localized: "Die Split-Beträge (|\(sum.description)|) ergeben nicht den Transaktionsbetrag (|\(parentMagnitude.description)|)."))
        }
        return .valid
    }
}

enum TransactionSplitValidationResult: Equatable {
    case valid
    case invalid(String)
}

/// Category selection follows split attribution; a split replaces its parent's category.
enum TransactionCategoryScope {
    static func projectingAmounts(
        transactions: [Transaction],
        splitLines: [TransactionSplitLine],
        categoryIDs: Set<UUID>
    ) -> [Transaction] {
        guard !categoryIDs.isEmpty else { return transactions }
        let byParent = Dictionary(grouping: splitLines, by: \.parentTransactionID)
        return transactions.compactMap { transaction in
            guard let lines = byParent[transaction.id], !lines.isEmpty else {
                return transaction.categoryID.map { categoryIDs.contains($0) } == true ? transaction : nil
            }
            let selected = lines.filter { $0.categoryID.map { categoryIDs.contains($0) } == true }
            guard !selected.isEmpty else { return nil }
            var projected = transaction
            let sign: Decimal = transaction.amount.amount < 0 ? -1 : 1
            projected.amount = Money(
                amount: sign * selected.reduce(Decimal.zero) { $0 + $1.amount },
                currency: transaction.amount.currency
            )
            return projected
        }
    }
}
