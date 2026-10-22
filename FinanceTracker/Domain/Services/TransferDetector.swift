import Foundation

struct TransferCandidate: Identifiable, Hashable, Sendable {
    let debitTransactionID: UUID
    let creditTransactionID: UUID
    let amount: Decimal
    let currency: CurrencyCode
    let daysApart: Int

    var id: String { "\(debitTransactionID.uuidString)|\(creditTransactionID.uuidString)" }
}

struct TransferDetector: Sendable {
    var maxDaysApart: Int = 4
    var amountTolerance = Decimal(string: "0.01")!

    /// Detects one-to-one transfer pairs greedily, processing debits by
    /// `bookedAt` and then UUID. Credits are indexed by currency and local
    /// calendar day. A match must be on another account, within the amount
    /// tolerance and at most `maxDaysApart` calendar days away.
    ///
    /// If several credits qualify, the stable tie-break is calendar-day
    /// distance, credit display date and credit UUID. The old implementation
    /// specified only the distance; its final choice depended on input order.
    func detect(
        transactions: [Transaction],
        baseCurrency: CurrencyCode,
        calendar: Calendar = .current
    ) -> [TransferCandidate] {
        guard maxDaysApart >= 0, amountTolerance >= 0 else { return [] }

        let policy = CashflowPolicy.shared
        let outflows = transactions.filter {
            $0.status != .reversed && $0.status != .cancelled
                && policy.contribution(for: $0).isSpendingLike
                && $0.amount.isNegative
        }
        .sorted(by: debitComesBefore)

        let inflows = transactions.filter { transaction in
            transaction.status != .reversed && transaction.status != .cancelled
                && transaction.amount.isPositive
                && (transaction.categoryID == nil || transaction.categoryID == Category.transfers.id)
                && transaction.amount.currency == baseCurrency
        }

        var index = TransferCreditIndex(transactions: inflows, calendar: calendar)
        var candidates: [TransferCandidate] = []
        candidates.reserveCapacity(Swift.min(outflows.count, inflows.count))

        for outflow in outflows {
            let amount = abs(outflow.amount.amount)
            guard let match = index.bestMatch(
                currency: outflow.amount.currency,
                amount: amount,
                tolerance: amountTolerance,
                date: outflow.displayDate,
                excludingAccountID: outflow.accountID,
                maxDaysApart: maxDaysApart,
                calendar: calendar
            ) else {
                continue
            }

            index.consume(match)
            candidates.append(
                TransferCandidate(
                    debitTransactionID: outflow.id,
                    creditTransactionID: match.transaction.id,
                    amount: amount,
                    currency: outflow.amount.currency,
                    daysApart: match.daysApart
                )
            )
        }

        return candidates
    }

    private func debitComesBefore(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
        let lhsBookedAt = lhs.bookedAt ?? .distantPast
        let rhsBookedAt = rhs.bookedAt ?? .distantPast
        if lhsBookedAt != rhsBookedAt { return lhsBookedAt < rhsBookedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct TransferCreditIndex {
    fileprivate struct Key: Hashable {
        let currency: CurrencyCode
        let day: Date
    }

    struct Match {
        fileprivate let key: Key
        let entryIndex: Int
        let transaction: Transaction
        let daysApart: Int

        fileprivate init(key: Key, entryIndex: Int, transaction: Transaction, daysApart: Int) {
            self.key = key
            self.entryIndex = entryIndex
            self.transaction = transaction
            self.daysApart = daysApart
        }
    }

    private var buckets: [Key: TransferDayBucket]

    init(transactions: [Transaction], calendar: Calendar) {
        var grouped: [Key: [Transaction]] = [:]
        grouped.reserveCapacity(transactions.count)
        for transaction in transactions {
            let key = Key(
                currency: transaction.amount.currency,
                day: calendar.startOfDay(for: transaction.displayDate)
            )
            grouped[key, default: []].append(transaction)
        }
        buckets = grouped.mapValues(TransferDayBucket.init)
    }

    mutating func bestMatch(
        currency: CurrencyCode,
        amount: Decimal,
        tolerance: Decimal,
        date: Date,
        excludingAccountID: UUID,
        maxDaysApart: Int,
        calendar: Calendar
    ) -> Match? {
        let debitDay = calendar.startOfDay(for: date)
        var best: Match?

        for offset in (-maxDaysApart)...maxDaysApart {
            guard let candidateDate = calendar.date(byAdding: .day, value: offset, to: debitDay) else {
                continue
            }
            let key = Key(currency: currency, day: calendar.startOfDay(for: candidateDate))
            guard let bucket = buckets[key],
                  let entry = bucket.bestMatch(
                    amount: amount,
                    tolerance: tolerance,
                    excludingAccountID: excludingAccountID
                  ) else {
                continue
            }

            let candidate = Match(
                key: key,
                entryIndex: entry.index,
                transaction: entry.transaction,
                daysApart: abs(offset)
            )
            if best.map({ matchComesBefore(candidate, $0) }) ?? true {
                best = candidate
            }
        }

        return best
    }

    mutating func consume(_ match: Match) {
        buckets[match.key]?.consume(entryAt: match.entryIndex)
    }

    private func matchComesBefore(_ lhs: Match, _ rhs: Match) -> Bool {
        if lhs.daysApart != rhs.daysApart { return lhs.daysApart < rhs.daysApart }
        if lhs.transaction.displayDate != rhs.transaction.displayDate {
            return lhs.transaction.displayDate < rhs.transaction.displayDate
        }
        return lhs.transaction.id.uuidString < rhs.transaction.id.uuidString
    }
}

/// An amount-sorted segment tree. Every node keeps the best two credits from
/// distinct accounts, which is sufficient to answer an amount-range query
/// while excluding the debit account. Consuming a credit updates one tree path.
private struct TransferDayBucket {
    struct Entry {
        let index: Int
        let transaction: Transaction
    }

    private struct Summary {
        var entryIndices: [Int] = []
    }

    private let entries: [Transaction]
    private let leafCount: Int
    private var tree: [Summary]

    init(_ transactions: [Transaction]) {
        entries = transactions.sorted {
            if $0.amount.amount != $1.amount.amount { return $0.amount.amount < $1.amount.amount }
            if $0.displayDate != $1.displayDate { return $0.displayDate < $1.displayDate }
            return $0.id.uuidString < $1.id.uuidString
        }

        var size = 1
        while size < entries.count { size *= 2 }
        leafCount = size
        tree = Array(repeating: Summary(), count: size * 2)

        for index in entries.indices {
            tree[size + index] = Summary(entryIndices: [index])
        }
        if size > 1 {
            for node in stride(from: size - 1, through: 1, by: -1) {
                tree[node] = merged(tree[node * 2], tree[node * 2 + 1])
            }
        }
    }

    func bestMatch(
        amount: Decimal,
        tolerance: Decimal,
        excludingAccountID: UUID
    ) -> Entry? {
        let lowerIndex = lowerBound(for: amount - tolerance)
        let upperIndex = upperBound(for: amount + tolerance)
        guard lowerIndex < upperIndex else { return nil }

        let summary = query(lowerIndex..<upperIndex)
        guard let index = summary.entryIndices.first(where: {
            entries[$0].accountID != excludingAccountID
        }) else {
            return nil
        }
        return Entry(index: index, transaction: entries[index])
    }

    mutating func consume(entryAt index: Int) {
        var node = leafCount + index
        tree[node] = Summary()
        node /= 2
        while node >= 1 {
            tree[node] = merged(tree[node * 2], tree[node * 2 + 1])
            if node == 1 { break }
            node /= 2
        }
    }

    private func lowerBound(for amount: Decimal) -> Int {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].amount.amount < amount {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func upperBound(for amount: Decimal) -> Int {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].amount.amount <= amount {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func query(_ range: Range<Int>) -> Summary {
        var lower = range.lowerBound + leafCount
        var upper = range.upperBound + leafCount
        var result = Summary()

        while lower < upper {
            if !lower.isMultiple(of: 2) {
                result = merged(result, tree[lower])
                lower += 1
            }
            if !upper.isMultiple(of: 2) {
                upper -= 1
                result = merged(result, tree[upper])
            }
            lower /= 2
            upper /= 2
        }
        return result
    }

    private func merged(_ lhs: Summary, _ rhs: Summary) -> Summary {
        let ordered = (lhs.entryIndices + rhs.entryIndices).sorted(by: entryComesBefore)
        var result: [Int] = []
        result.reserveCapacity(2)
        for index in ordered where !result.contains(where: { entries[$0].accountID == entries[index].accountID }) {
            result.append(index)
            if result.count == 2 { break }
        }
        return Summary(entryIndices: result)
    }

    private func entryComesBefore(_ lhs: Int, _ rhs: Int) -> Bool {
        let lhsTransaction = entries[lhs]
        let rhsTransaction = entries[rhs]
        if lhsTransaction.displayDate != rhsTransaction.displayDate {
            return lhsTransaction.displayDate < rhsTransaction.displayDate
        }
        return lhsTransaction.id.uuidString < rhsTransaction.id.uuidString
    }
}

private extension CashflowContribution {
    var isSpendingLike: Bool {
        if case .spending = self { return true }
        return false
    }
}
