import Foundation

/// Auffälligkeiten, die die App von sich aus nennt, statt nur Zahlen zu
/// zeigen: ein Abo wurde teurer, eine Abbuchung kam doppelt, ein Betrag ist
/// für den Händler ungewöhnlich hoch, ein Budget ist beim aktuellen Tempo vor
/// Periodenende aufgebraucht. Alles lokal aus den vorhandenen Buchungen.
struct SpendingInsight: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, Hashable {
        case subscriptionPriceIncrease
        case possibleDuplicate
        case unusuallyHigh
        case budgetRunsOut
    }

    let kind: Kind
    /// Stabil je Ursache, damit „Ausblenden" bei der nächsten Berechnung hält.
    let id: String
    let title: String
    let detail: String
    /// Buchungen, um die es geht (zum Öffnen in der Liste).
    let transactionIDs: [UUID]
    /// Größer = wichtiger (Sortierung).
    let weight: Int
}

struct SpendingInsightDetector: Sendable {
    /// Nur Ereignisse der letzten Tage zählen als neu.
    var recentDays = 35
    var duplicateWindowDays = 2
    var unusualFactor: Decimal = 3
    var unusualMinimum: Decimal = 50
    var priceIncreaseMinimumFraction: Decimal = Decimal(string: "0.03")!

    func detect(
        transactions: [Transaction],
        commitments: [RecurringCommitment],
        budgetProgresses: [BudgetProgress],
        now: Date,
        calendar: Calendar = .current,
        limit: Int = 5
    ) -> [SpendingInsight] {
        let policy = CashflowPolicy.shared
        let expenses = transactions.filter { txn in
            guard txn.status.isEffective, !policy.isExcluded(txn), txn.kind != .transfer else { return false }
            if case .spending(let delta) = policy.contribution(for: txn) { return delta > 0 }
            return false
        }
        guard let recentStart = calendar.date(byAdding: .day, value: -recentDays, to: now) else { return [] }

        var insights: [SpendingInsight] = []
        insights += priceIncreases(commitments: commitments, transactions: transactions, recentStart: recentStart, calendar: calendar)
        insights += duplicates(expenses: expenses, recentStart: recentStart, calendar: calendar)
        insights += unusual(expenses: expenses, recentStart: recentStart)
        insights += budgetDepletion(budgetProgresses, now: now, calendar: calendar)
        return Array(insights.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.id < $1.id }.prefix(limit))
    }

    // MARK: - Abo teurer

    private func priceIncreases(
        commitments: [RecurringCommitment],
        transactions: [Transaction],
        recentStart: Date,
        calendar: Calendar
    ) -> [SpendingInsight] {
        commitments.compactMap { commitment in
            guard commitment.status == .active, commitment.direction == .expense,
                  commitment.matchingMerchantKey != nil else { return nil }
            let matches = RecurringPaymentMatcher.matchingTransactions(for: commitment, in: transactions, calendar: calendar)
                .sorted { $0.displayDate < $1.displayDate }
            guard matches.count >= 2, let latest = matches.last, let previous = matches.dropLast().last,
                  latest.displayDate >= recentStart else { return nil }
            let new = abs(latest.amount.amount)
            let old = abs(previous.amount.amount)
            guard old > 0, new - old > max(Decimal(string: "0.50")!, old * priceIncreaseMinimumFraction) else { return nil }
            let currency = latest.amount.currency
            return SpendingInsight(
                kind: .subscriptionPriceIncrease,
                id: "price-\(commitment.id.uuidString)-\(latest.id.uuidString)",
                title: String(localized: "\(commitment.name) ist teurer geworden"),
                detail: String(localized: "Zuletzt \(Self.format(new, currency)) statt \(Self.format(old, currency)). Lohnt sich ein Blick in den Vertrag?"),
                transactionIDs: [previous.id, latest.id],
                weight: 3
            )
        }
    }

    // MARK: - Doppelte Abbuchung

    private func duplicates(expenses: [Transaction], recentStart: Date, calendar: Calendar) -> [SpendingInsight] {
        let recent = expenses.filter { $0.displayDate >= recentStart }
        let groups = Dictionary(grouping: recent) { txn in
            "\(txn.accountID.uuidString)|\(txn.amount.currency.rawValue)|\(txn.amount.amount)|\(CategoryRuleEngine.normalizedKey(txn.effectiveMerchantName))"
        }
        var result: [SpendingInsight] = []
        for (_, rows) in groups where rows.count >= 2 {
            let sorted = rows.sorted { $0.displayDate < $1.displayDate }
            for (first, second) in zip(sorted, sorted.dropFirst()) {
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: first.displayDate), to: calendar.startOfDay(for: second.displayDate)).day ?? 99
                guard days <= duplicateWindowDays else { continue }
                result.append(SpendingInsight(
                    kind: .possibleDuplicate,
                    id: "duplicate-\(first.id.uuidString)-\(second.id.uuidString)",
                    title: String(localized: "Doppelte Abbuchung bei \(second.effectiveMerchantName)?"),
                    detail: String(localized: "Zweimal \(Self.format(abs(second.amount.amount), second.amount.currency)) innerhalb von \(days + 1) Tagen. Falls es kein zweiter Einkauf war, bei der Bank nachfragen."),
                    transactionIDs: [first.id, second.id],
                    weight: 4
                ))
            }
        }
        return result
    }

    // MARK: - Ungewöhnlich hoch

    private func unusual(expenses: [Transaction], recentStart: Date) -> [SpendingInsight] {
        let byMerchant = Dictionary(grouping: expenses) { txn in
            "\(txn.amount.currency.rawValue)|\(CategoryRuleEngine.normalizedKey(txn.effectiveMerchantName))"
        }
        var result: [SpendingInsight] = []
        for (_, rows) in byMerchant {
            let history = rows.filter { $0.displayDate < recentStart }.map { abs($0.amount.amount) }.sorted()
            guard history.count >= 5 else { continue }
            let median = history[history.count / 2]
            for txn in rows where txn.displayDate >= recentStart {
                let amount = abs(txn.amount.amount)
                guard amount >= unusualMinimum, amount > median * unusualFactor else { continue }
                result.append(SpendingInsight(
                    kind: .unusuallyHigh,
                    id: "unusual-\(txn.id.uuidString)",
                    title: String(localized: "Ungewöhnlich hoher Betrag bei \(txn.effectiveMerchantName)"),
                    detail: String(localized: "\(Self.format(amount, txn.amount.currency)), sonst meist um \(Self.format(median, txn.amount.currency))."),
                    transactionIDs: [txn.id],
                    weight: 2
                ))
            }
        }
        return result
    }

    // MARK: - Budget läuft leer

    private func budgetDepletion(_ progresses: [BudgetProgress], now: Date, calendar: Calendar) -> [SpendingInsight] {
        progresses.compactMap { progress in
            guard progress.effectiveLimit > 0, !progress.isOverBudget, progress.spent > 0,
                  progress.period.contains(now) else { return nil }
            let elapsed = max(1, calendar.dateComponents([.day], from: progress.period.start, to: now).day ?? 1)
            let total = max(1, calendar.dateComponents([.day], from: progress.period.start, to: progress.period.end).day ?? 30)
            // Erst ab einer Woche Daten ist ein Tempo aussagekräftig.
            guard elapsed >= 7, elapsed < total else { return nil }
            let perDay = progress.spent / Decimal(elapsed)
            guard perDay > 0 else { return nil }
            // Erst runden: NSDecimalNumber.intValue liefert bei langen
            // Dezimalbrüchen falsche Werte.
            var exact = progress.effectiveLimit / perDay
            var rounded = Decimal()
            NSDecimalRound(&rounded, &exact, 0, .down)
            let daysUntilEmpty = NSDecimalNumber(decimal: rounded).intValue
            guard daysUntilEmpty < total,
                  let emptyDate = calendar.date(byAdding: .day, value: daysUntilEmpty, to: progress.period.start),
                  emptyDate > now else { return nil }
            return SpendingInsight(
                kind: .budgetRunsOut,
                id: "budget-\(progress.budget.id.uuidString)-\(Int(progress.period.start.timeIntervalSince1970))",
                title: String(localized: "Budget „\(progress.budget.name)“ reicht nicht bis zum Ende"),
                detail: String(localized: "Beim aktuellen Tempo ist es am \(emptyDate.formatted(.dateTime.day().month(.wide))) aufgebraucht."),
                transactionIDs: [],
                weight: 3
            )
        }
    }

    private static func format(_ value: Decimal, _ currency: CurrencyCode) -> String {
        value.formatted(.currency(code: currency.rawValue))
    }
}
