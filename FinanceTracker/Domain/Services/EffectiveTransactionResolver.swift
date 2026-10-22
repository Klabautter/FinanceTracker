import Foundation

struct EffectiveTransactionResolver: Sendable {
    func applying(
        annotations: [TransactionAnnotation],
        to transactions: [Transaction]
    ) -> [Transaction] {
        let annotationsByTransactionID = Dictionary(
            annotations.map { ($0.transactionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return transactions.map { transaction in
            guard let annotation = annotationsByTransactionID[transaction.id] else {
                return transaction
            }
            return applying(annotation: annotation, to: transaction)
        }
    }

    func applying(annotation: TransactionAnnotation, to transaction: Transaction) -> Transaction {
        var effective = transaction
        effective.note = annotation.note
        effective.reviewed = annotation.reviewed
        effective.excludedFromAnalytics = annotation.excludedFromAnalytics
        effective.tagIDs = annotation.tagIDs
        if let override = annotation.manualKindOverride {
            effective.kind = override
        }
        effective.updatedAt = max(transaction.updatedAt, annotation.updatedAt)
        return effective
    }
}
