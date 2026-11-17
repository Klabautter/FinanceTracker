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
        // Nur die benötigten Felder sortieren, keine Kopien ganzer
        // Buchungen (bei 100.000 Buchungen sonst rund 80 MB zusätzlich).
        let outflows = transactions.compactMap { transaction -> TransferDebit? in
            guard transaction.status.isEffective,
                  policy.contribution(for: transaction).isSpendingLike,
                  transaction.amount.isNegative else { return nil }
            return TransferDebit(transaction)
        }
        .sorted(by: TransferDebit.comesBefore)

        let inflows = transactions.filter { transaction in
            transaction.status.isEffective
                && transaction.amount.isPositive
                && (transaction.categoryID == nil
                    || transaction.categoryID == Category.transfers.id
                    || transaction.categoryID == Category.investments.id)
                && transaction.amount.currency == baseCurrency
        }

        var index = TransferCreditIndex(transactions: inflows, calendar: calendar)
        var candidates: [TransferCandidate] = []
        candidates.reserveCapacity(Swift.min(outflows.count, inflows.count))
        // Kalendertage einmal je Tag statt je Buchung und Abstand berechnen.
        var dayCache: [Date: Int] = [:]
        let toleranceUnits = TransferCredit.units(amountTolerance)

        for outflow in outflows {
            let amount = abs(outflow.amount.amount)
            let debitDay = index.dayNumber(for: outflow.displayDate, calendar: calendar, cache: &dayCache)
            guard let match = index.bestMatch(
                currency: outflow.amount.currency,
                amount: TransferCredit.units(amount),
                tolerance: toleranceUnits,
                debitDay: debitDay,
                excludingAccountID: outflow.accountID,
                maxDaysApart: maxDaysApart
            ) else {
                continue
            }

            index.consume(match)
            candidates.append(
                TransferCandidate(
                    debitTransactionID: outflow.id,
                    creditTransactionID: match.transactionID,
                    amount: amount,
                    currency: outflow.amount.currency,
                    daysApart: match.daysApart
                )
            )
        }

        return candidates
    }

}

/// Eine Abbuchung für den Abgleich: nur die Felder, die er braucht.
private struct TransferDebit {
    let id: UUID
    let accountID: UUID
    let bookedAt: Date?
    let displayDate: Date
    let amount: Money

    init(_ transaction: Transaction) {
        id = transaction.id
        accountID = transaction.accountID
        bookedAt = transaction.bookedAt
        displayDate = transaction.displayDate
        amount = transaction.amount
    }

    static func comesBefore(_ lhs: TransferDebit, _ rhs: TransferDebit) -> Bool {
        let lhsBookedAt = lhs.bookedAt ?? .distantPast
        let rhsBookedAt = rhs.bookedAt ?? .distantPast
        if lhsBookedAt != rhsBookedAt { return lhsBookedAt < rhsBookedAt }
        // Byteweiser UUID-Vergleich ordnet wie der frühere uuidString-
        // Vergleich (Hex-Ziffern steigen mit dem Nibble-Wert), ohne Strings.
        return lhs.id < rhs.id
    }
}

/// Nur die Felder, die der Abgleich braucht: keine Kopien ganzer Buchungen
/// in den Baumknoten.
private struct TransferCredit {
    let id: UUID
    let accountID: UUID
    /// Betrag in Zehntausendsteln: ganzzahlige Vergleiche statt Decimal.
    let amount: Int64
    let displayDate: Date

    /// Exakt für Beträge mit bis zu vier Nachkommastellen (Bankbeträge
    /// haben höchstens zwei); gerundet, nie über Double.
    static func units(_ value: Decimal) -> Int64 {
        var scaled = value * 10_000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}

private struct TransferCreditIndex {
    fileprivate struct Key: Hashable {
        let currency: CurrencyCode
        let day: Int
    }

    struct Match {
        fileprivate let key: Key
        let entryIndex: Int
        let transactionID: UUID
        let displayDate: Date
        let daysApart: Int
    }

    /// Je Währung die Tage; die Währung wird pro Ausgabe einmal gehasht.
    private var buckets: [CurrencyCode: [Int: TransferDayBucket]]
    /// Kalendertage als fortlaufende Nummern (Tage seit dem frühesten Tag),
    /// damit „±n Tage“ eine Addition ist statt einer Kalenderrechnung.
    private let origin: Date

    init(transactions: [Transaction], calendar: Calendar) {
        origin = Date(timeIntervalSinceReferenceDate: 0)
        var cache: [Date: Int] = [:]
        var grouped: [Key: [TransferCredit]] = [:]
        grouped.reserveCapacity(transactions.count)
        for transaction in transactions {
            let key = Key(
                currency: transaction.amount.currency,
                day: Self.dayNumber(for: transaction.displayDate, origin: origin, calendar: calendar, cache: &cache)
            )
            grouped[key, default: []].append(TransferCredit(
                id: transaction.id,
                accountID: transaction.accountID,
                amount: TransferCredit.units(transaction.amount.amount),
                displayDate: transaction.displayDate
            ))
        }
        var byCurrency: [CurrencyCode: [Int: TransferDayBucket]] = [:]
        for (key, credits) in grouped {
            byCurrency[key.currency, default: [:]][key.day] = TransferDayBucket(credits)
        }
        buckets = byCurrency
    }

    func dayNumber(for date: Date, calendar: Calendar, cache: inout [Date: Int]) -> Int {
        Self.dayNumber(for: date, origin: origin, calendar: calendar, cache: &cache)
    }

    /// Kalendertag-Nummer in der Zeitzone des Kalenders (Sommerzeit-fest:
    /// gezählt werden Kalendertage, nicht 24-Stunden-Blöcke).
    private static func dayNumber(for date: Date, origin: Date, calendar: Calendar, cache: inout [Date: Int]) -> Int {
        let day = calendar.startOfDay(for: date)
        if let cached = cache[day] { return cached }
        let number = calendar.dateComponents([.day], from: calendar.startOfDay(for: origin), to: day).day ?? 0
        cache[day] = number
        return number
    }

    mutating func bestMatch(
        currency: CurrencyCode,
        amount: Int64,
        tolerance: Int64,
        debitDay: Int,
        excludingAccountID: UUID,
        maxDaysApart: Int
    ) -> Match? {
        var best: Match?
        guard let days = buckets[currency] else { return nil }
        for offset in (-maxDaysApart)...maxDaysApart {
            let key = Key(currency: currency, day: debitDay + offset)
            guard let bucket = days[key.day],
                  let entryIndex = bucket.bestMatch(
                    amount: amount,
                    tolerance: tolerance,
                    excludingAccountID: excludingAccountID
                  ) else {
                continue
            }
            let credit = bucket.entries[entryIndex]
            let candidate = Match(
                key: key,
                entryIndex: entryIndex,
                transactionID: credit.id,
                displayDate: credit.displayDate,
                daysApart: abs(offset)
            )
            if best.map({ Self.matchComesBefore(candidate, $0) }) ?? true {
                best = candidate
            }
        }
        return best
    }

    mutating func consume(_ match: Match) {
        buckets[match.key.currency]?[match.key.day]?.consume(entryAt: match.entryIndex)
    }

    private static func matchComesBefore(_ lhs: Match, _ rhs: Match) -> Bool {
        if lhs.daysApart != rhs.daysApart { return lhs.daysApart < rhs.daysApart }
        if lhs.displayDate != rhs.displayDate { return lhs.displayDate < rhs.displayDate }
        return lhs.transactionID < rhs.transactionID
    }
}

/// An amount-sorted segment tree. Every node keeps the best two credits from
/// distinct accounts, which is sufficient to answer an amount-range query
/// while excluding the debit account. Consuming a credit updates one tree path.
private struct TransferDayBucket {
    /// Bis zu zwei Einträge verschiedener Konten, beste zuerst; -1 = leer.
    private struct Summary {
        var first = -1
        var second = -1
    }

    let entries: [TransferCredit]
    private let leafCount: Int
    private var tree: [Summary]

    init(_ credits: [TransferCredit]) {
        entries = credits.sorted {
            if $0.amount != $1.amount { return $0.amount < $1.amount }
            if $0.displayDate != $1.displayDate { return $0.displayDate < $1.displayDate }
            return $0.id < $1.id
        }

        var size = 1
        while size < entries.count { size *= 2 }
        leafCount = size
        tree = Array(repeating: Summary(), count: size * 2)

        for index in entries.indices {
            tree[size + index] = Summary(first: index)
        }
        if size > 1 {
            for node in stride(from: size - 1, through: 1, by: -1) {
                tree[node] = merged(tree[node * 2], tree[node * 2 + 1])
            }
        }
    }

    /// Index des besten Eintrags im Betragsfenster auf einem anderen Konto.
    func bestMatch(amount: Int64, tolerance: Int64, excludingAccountID: UUID) -> Int? {
        let lowerIndex = lowerBound(for: amount - tolerance)
        let upperIndex = upperBound(for: amount + tolerance)
        guard lowerIndex < upperIndex else { return nil }

        let summary = query(lowerIndex..<upperIndex)
        for index in [summary.first, summary.second] where index >= 0 {
            if entries[index].accountID != excludingAccountID { return index }
        }
        return nil
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

    private func lowerBound(for amount: Int64) -> Int {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].amount < amount {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func upperBound(for amount: Int64) -> Int {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].amount <= amount {
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

    /// Die zwei besten Einträge aus höchstens vier, je Konto nur einer.
    private func merged(_ lhs: Summary, _ rhs: Summary) -> Summary {
        var result = Summary()
        // Vier Kandidaten ohne Array: zweimal das Beste der Restmenge wählen.
        let candidates = (lhs.first, lhs.second, rhs.first, rhs.second)
        func pick(excludingAccount: UUID?) -> Int {
            var best = -1
            for index in [candidates.0, candidates.1, candidates.2, candidates.3] where index >= 0 {
                if let excludingAccount, entries[index].accountID == excludingAccount { continue }
                if best < 0 || entryComesBefore(index, best) { best = index }
            }
            return best
        }
        result.first = pick(excludingAccount: nil)
        if result.first >= 0 {
            result.second = pick(excludingAccount: entries[result.first].accountID)
        }
        return result
    }

    private func entryComesBefore(_ lhs: Int, _ rhs: Int) -> Bool {
        let lhsCredit = entries[lhs]
        let rhsCredit = entries[rhs]
        if lhsCredit.displayDate != rhsCredit.displayDate {
            return lhsCredit.displayDate < rhsCredit.displayDate
        }
        return lhsCredit.id < rhsCredit.id
    }
}

private extension CashflowContribution {
    var isSpendingLike: Bool {
        if case .spending = self { return true }
        return false
    }
}
