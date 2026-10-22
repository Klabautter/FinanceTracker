import Foundation

struct TransactionCollectionResolver: Sendable {
    func contains(
        _ transaction: Transaction,
        in collection: TransactionCollection,
        override: TransactionCollectionOverride? = nil
    ) -> Bool {
        switch override?.decision {
        case .include:
            return true
        case .exclude:
            return false
        case nil:
            return collection.accountIDs.contains(transaction.accountID)
                && transaction.displayDate >= collection.startDate
                && transaction.displayDate < collection.endDateExclusive
        }
    }
}

struct TransactionCollectionCurrencySummary: Sendable, Hashable {
    let currency: CurrencyCode
    let spending: Decimal
    let income: Decimal

    var netCashflow: Decimal { income - spending }
}

struct TransactionCollectionSnapshot: Sendable, Hashable {
    let collection: TransactionCollection
    let transactions: [Transaction]
    let currencySummaries: [TransactionCollectionCurrencySummary]
}

struct TransactionCollectionSummaryCalculator: Sendable {
    private let policy = CashflowPolicy.shared

    func summaries(for transactions: [Transaction]) -> [TransactionCollectionCurrencySummary] {
        var values: [CurrencyCode: (spending: Decimal, income: Decimal)] = [:]

        for transaction in transactions {
            guard !policy.isExcluded(transaction),
                  policy.isRelevantForAnalytics(transaction, baseCurrency: transaction.amount.currency) else {
                continue
            }

            let currency = transaction.amount.currency
            switch policy.contribution(for: transaction) {
            case .spending(let amount):
                values[currency, default: (0, 0)].spending += amount
            case .income(let amount):
                values[currency, default: (0, 0)].income += amount
            case .neutral:
                break
            }
        }

        return values.map { currency, value in
            TransactionCollectionCurrencySummary(
                currency: currency,
                spending: max(0, value.spending),
                income: value.income
            )
        }
        .sorted { $0.currency.rawValue < $1.currency.rawValue }
    }
}
