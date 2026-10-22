import Foundation

enum CashflowContribution: Sendable, Hashable {
    case spending(Decimal)
    case income(Decimal)
    case neutral
}

struct CashflowPolicy: Sendable {
    static let shared = CashflowPolicy()

    func isExcluded(_ transaction: Transaction) -> Bool {
        transaction.excludedFromAnalytics
    }

    func contribution(for transaction: Transaction) -> CashflowContribution {
        let magnitude = abs(transaction.amount.amount)

        switch transaction.kind {
        case .purchase, .fee:
            return .spending(magnitude)

        case .refund, .cashback:
            return .spending(-magnitude)

        case .income:
            return .income(transaction.amount.amount)

        case .transfer:
            return .neutral

        case .unknown:
            if transaction.amount.isNegative {
                return .spending(magnitude)
            }
            return .income(transaction.amount.amount)
        }
    }

    func countsTowardBreakdowns(_ transaction: Transaction) -> Bool {
        switch transaction.kind {
        case .purchase, .fee:
            return transaction.amount.isNegative
        case .unknown:
            return transaction.amount.isNegative
        case .refund, .cashback, .income, .transfer:
            return false
        }
    }

    func isRelevantForAnalytics(_ transaction: Transaction, baseCurrency: CurrencyCode) -> Bool {
        transaction.status != .reversed
            && transaction.status != .cancelled
    }
}
