import Foundation

struct RecurringSeries: Identifiable, Hashable, Sendable {
    enum Cadence: String, Sendable {
        case weekly
        case monthly
        case quarterly
        case yearly

        var displayName: String {
            switch self {
            case .weekly: String(localized: "wöchentlich")
            case .monthly: String(localized: "monatlich")
            case .quarterly: String(localized: "quartalsweise")
            case .yearly: String(localized: "jährlich")
            }
        }
    }

    let id: String
    let merchantKey: String
    let accountID: UUID
    let displayName: String
    let cadence: Cadence
    let medianIntervalDays: Int
    let medianAmount: Decimal
    let currency: CurrencyCode
    let occurrences: [Date]
    let confidence: Double
    let nextExpectedDate: Date

    var isFixedCost: Bool { true }
}

struct RecurringPaymentsDetector: Sendable {
    struct Tolerance: Sendable {
        var intervalDays: Int = 4
        var amountFraction: Decimal = Decimal(string: "0.06")!
        var minimumOccurrences: Int = 3
    }

    private let tolerance: Tolerance
    private let normalizer = MerchantNormalizer()

    init(tolerance: Tolerance = Tolerance()) {
        self.tolerance = tolerance
    }

    func detect(
        transactions: [Transaction],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [RecurringSeries] {
        let policy = CashflowPolicy.shared

        var groups: [String: [Transaction]] = [:]
        var canonicalCache: [String: String] = [:]
        for txn in transactions {
            guard txn.status == .booked,
                  !policy.isExcluded(txn),
                  case .spending(let magnitude) = policy.contribution(for: txn),
                  magnitude > 0 else { continue }

            let raw = txn.merchantDisplayName ?? txn.rawMerchantName ?? ""
            let canonical: String
            if let cached = canonicalCache[raw] {
                canonical = cached
            } else {
                canonical = normalizer.canonicalDisplayName(from: raw) ?? raw
                canonicalCache[raw] = canonical
            }
            guard !canonical.isEmpty, canonical != "Unbekannt" else { continue }

            let merchantKey = txn.merchantID?.uuidString ?? CategoryRuleEngine.normalizedKey(canonical)
            let groupKey = merchantKey + "|" + txn.accountID.uuidString + "|" + txn.amount.currency.rawValue
            groups[groupKey, default: []].append(txn)
        }

        var series: [RecurringSeries] = []

        for (key, txns) in groups where txns.count >= tolerance.minimumOccurrences {
            let sorted = txns.sorted {
                ($0.bookedAt ?? $0.authorizedAt ?? $0.createdAt) < ($1.bookedAt ?? $1.authorizedAt ?? $1.createdAt)
            }

            let dates = sorted.map { $0.bookedAt ?? $0.authorizedAt ?? $0.createdAt }
            let amounts = sorted.map { abs($0.amount.amount) }
            let currency = sorted[0].amount.currency

            guard dates.count >= 2 else { continue }

            var gaps: [Int] = []
            for index in 1..<dates.count {
                gaps.append(calendar.dateComponents([.day], from: dates[index - 1], to: dates[index]).day ?? 0)
            }

            guard let interval = median(gaps), interval > 0,
                  let cadence = Self.cadence(forDays: interval) else { continue }

            let allowedDeviation = max(tolerance.intervalDays, Int((Double(interval) * 0.25).rounded()))
            let matchingGaps = gaps.filter { abs($0 - interval) <= allowedDeviation }.count
            let confidence = Double(matchingGaps) / Double(max(1, gaps.count))

            guard confidence >= 0.6 else { continue }

            let medianAmountValue = medianDecimal(amounts) ?? 0

            let amountTolerance = max(Decimal(string: "0.50")!, medianAmountValue * tolerance.amountFraction)
            let consistentAmounts = amounts.filter { abs($0 - medianAmountValue) <= amountTolerance }.count
            let amountConfidence = Double(consistentAmounts) / Double(amounts.count)

            let combinedConfidence = (confidence + amountConfidence) / 2
            guard combinedConfidence >= 0.6 else { continue }

            guard let lastDate = dates.last,
                  let nextExpected = calendar.date(byAdding: .day, value: interval, to: lastDate) else { continue }
            guard nextExpected > now.addingTimeInterval(-90 * 24 * 3600) else { continue }

            let displayName = sorted.compactMap(\.merchantDisplayName).first
                ?? sorted.compactMap(\.rawMerchantName).first
                ?? key

            series.append(
                RecurringSeries(
                    id: key,
                    merchantKey: sorted[0].merchantID?.uuidString
                        ?? CategoryRuleEngine.normalizedKey(normalizer.canonicalDisplayName(from: sorted[0].effectiveMerchantName) ?? sorted[0].effectiveMerchantName),
                    accountID: sorted[0].accountID,
                    displayName: displayName,
                    cadence: cadence,
                    medianIntervalDays: interval,
                    medianAmount: medianAmountValue,
                    currency: currency,
                    occurrences: dates,
                    confidence: combinedConfidence,
                    nextExpectedDate: nextExpected
                )
            )
        }

        return series.sorted {
            if $0.currency.rawValue != $1.currency.rawValue {
                return $0.currency.rawValue < $1.currency.rawValue
            }
            if $0.medianAmount != $1.medianAmount { return $0.medianAmount > $1.medianAmount }
            return $0.displayName < $1.displayName
        }
    }

    static func cadence(forDays days: Int) -> RecurringSeries.Cadence? {
        switch days {
        case 5...9: .weekly
        case 24...36: .monthly
        case 80...105: .quarterly
        case 340...380: .yearly
        default: nil
        }
    }

    private func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sortedValues = values.sorted()
        let mid = sortedValues.count / 2
        if sortedValues.count % 2 == 0 {
            return (sortedValues[mid - 1] + sortedValues[mid]) / 2
        }
        return sortedValues[mid]
    }

    private func medianDecimal(_ values: [Decimal]) -> Decimal? {
        guard !values.isEmpty else { return nil }
        let sortedValues = values.sorted()
        let mid = sortedValues.count / 2
        if sortedValues.count % 2 == 0 {
            return (sortedValues[mid - 1] + sortedValues[mid]) / 2
        }
        return sortedValues[mid]
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sortedValues = values.sorted()
        let mid = sortedValues.count / 2
        if sortedValues.count % 2 == 0 {
            return (sortedValues[mid - 1] + sortedValues[mid]) / 2
        }
        return sortedValues[mid]
    }
}
