import Foundation

/// WP9: Gemeinsame Budget-Contribution-Pipeline.
///
/// Transaction → EffectiveTransactionResolver (vom Aufrufer angewendet) →
/// Split Resolution → Währungsumrechnung → CashflowPolicy → Budget Match →
/// Contribution.
///
/// `BudgetCalculator.progress` summiert über dieselbe Pipeline, der
/// Budget-Detail-Trend/Liste zeigt die einzelnen Beiträge: Header und
/// Trend-Ende können deshalb nie auseinanderlaufen.
struct BudgetContribution: Sendable, Identifiable, Equatable {
    /// Transaktions-ID bzw. Split-Line-ID.
    let id: UUID
    let transactionID: UUID
    /// Contribution lt. CashflowPolicy (signed; Refund reduziert).
    /// Immer in der Budget-Währung.
    let amount: Decimal
    let date: Date
    let merchantName: String
    let isSplitLine: Bool
    let note: String?
    /// Ursprungswährung, falls der Beitrag zum Referenzkurs in die
    /// Budget-Währung umgerechnet wurde (`nil` = native Budget-Währung).
    /// Die UI muss umgerechnete Beiträge als solche ausweisen.
    var convertedFrom: CurrencyCode?
}

/// Ergebnis der Contribution-Pipeline inklusive der bewusst NICHT
/// gezählten Fremdwährungen (kein stiller Fallback).
struct BudgetContributionResult: Sendable, Equatable {
    let contributions: [BudgetContribution]
    /// Währungen ohne Referenzkurs, deren Transaktionen sonst auf dieses
    /// Budget gezählt hätten. Muss sichtbar gemeldet werden.
    let excludedCurrencies: Set<CurrencyCode>

    static let empty = BudgetContributionResult(contributions: [], excludedCurrencies: [])
}

struct BudgetContributionCalculator: Sendable {
    private let converter: CurrencyConverter

    init(converter: CurrencyConverter = CurrencyConverter()) {
        self.converter = converter
    }

    /// Alle Beiträge eines Budgets in der Periode.
    ///
    /// Voraussetzung: `transactions` sind bereits effective (Annotationen
    /// angewendet) und periodengescoped.
    func contributions(
        budget: Budget,
        transactions: [Transaction],
        splitLines: [TransactionSplitLine],
        period: DateInterval,
        calendar: Calendar = .current
    ) -> [BudgetContribution] {
        result(
            budget: budget,
            transactions: transactions,
            splitLines: splitLines,
            period: period,
            calendar: calendar
        ).contributions
    }

    /// Beiträge + Meldung der nicht umrechenbaren Fremdwährungen.
    ///
    /// Fremdwährungs-Transaktionen werden zum Referenzkurs in die
    /// Budget-Währung umgerechnet und zählen mit, identisch zur
    /// Analytics-Semantik.
    /// Ohne Referenzkurs bleibt die Transaktion ausgeschlossen und wird
    /// über `excludedCurrencies` gemeldet.
    func result(
        budget: Budget,
        transactions: [Transaction],
        splitLines: [TransactionSplitLine],
        period: DateInterval,
        calendar: Calendar = .current
    ) -> BudgetContributionResult {
        let policy = CashflowPolicy.shared
        let splitsByParent = Dictionary(grouping: splitLines, by: \.parentTransactionID)
        let parentIDsWithSplits = Set(splitsByParent.keys)
        let accountScope = budget.accountIDs
        // WP9-Perf: Parent-Lookup als Dictionary statt linearer Suche pro
        // Split-Gruppe (vorher O(splits × transactions)).
        let transactionsByID = Dictionary(
            transactions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [BudgetContribution] = []
        var excludedCurrencies = Set<CurrencyCode>()

        /// Alle Nicht-Währungs-Bedingungen eines Budget-Treffers.
        func passesNonCurrencyScope(_ txn: Transaction) -> Bool {
            txn.status != .reversed
                && txn.status != .cancelled
                && !policy.isExcluded(txn)
                && period.containsHalfOpen(txn.displayDate)
                && (accountScope.isEmpty || accountScope.contains(txn.accountID))
        }

        /// Kurs in die Budget-Währung; `nil` meldet die Währung als
        /// ausgeschlossen (nur für sonst passende Transaktionen).
        func rateToBudgetCurrency(_ txn: Transaction) -> Decimal? {
            guard let rate = converter.rate(from: txn.amount.currency, to: budget.currency) else {
                excludedCurrencies.insert(txn.amount.currency)
                return nil
            }
            return rate
        }

        // 1) Split-Lines (#71): Parent wird nicht zusätzlich gezählt.
        for (parentID, lines) in splitsByParent {
            guard let parent = transactionsByID[parentID] else { continue }
            guard passesNonCurrencyScope(parent) else { continue }
            guard case .spending(let parentContribution) = policy.contribution(for: parent) else { continue }

            let coversAll = budget.categoryIDs.isEmpty && budget.isSalaryCycle
            let matchingLines = lines.filter { line in
                coversAll || line.categoryID.map { budget.categoryIDs.contains($0) } ?? false
            }
            guard !matchingLines.isEmpty else { continue }

            guard let rate = rateToBudgetCurrency(parent) else { continue }
            let isConverted = parent.amount.currency != budget.currency
            let direction: Decimal = parentContribution < 0 ? -1 : (parentContribution > 0 ? 1 : 0)

            for line in matchingLines {
                result.append(BudgetContribution(
                    id: line.id,
                    transactionID: parent.id,
                    amount: direction * line.amount * rate,
                    date: parent.displayDate,
                    merchantName: parent.effectiveMerchantName,
                    isSplitLine: true,
                    note: line.note,
                    convertedFrom: isConverted ? parent.amount.currency : nil
                ))
            }
        }

        // 2) Transaktionen ohne Splits, multi-category (#100).
        for txn in transactions {
            guard !parentIDsWithSplits.contains(txn.id),
                  passesNonCurrencyScope(txn),
                  matchesCategory(txn, budget: budget) else { continue }

            guard let rate = rateToBudgetCurrency(txn) else { continue }
            let isConverted = txn.amount.currency != budget.currency

            // Umrechnung VOR der Policy: Vorzeichen-/Refund-Semantik bleibt
            // unverändert (Kurse sind immer positiv).
            var converted = txn
            converted.amount = Money(amount: txn.amount.amount * rate, currency: budget.currency)

            // .neutral (Transfer) zählt nicht (#38)
            guard case .spending(let contribution) = policy.contribution(for: converted) else { continue }
            result.append(BudgetContribution(
                id: txn.id,
                transactionID: txn.id,
                amount: contribution,
                date: txn.displayDate,
                merchantName: txn.effectiveMerchantName,
                isSplitLine: false,
                note: nil,
                convertedFrom: isConverted ? txn.amount.currency : nil
            ))
        }

        return BudgetContributionResult(
            contributions: result.sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.id.uuidString < $1.id.uuidString
            },
            excludedCurrencies: excludedCurrencies
        )
    }

    /// Summe der Beiträge, identisch mit `BudgetProgress.spent`.
    func total(_ contributions: [BudgetContribution]) -> Decimal {
        contributions.reduce(into: Decimal(0)) { partial, contribution in
            partial += contribution.amount
        }
    }

    private func matchesCategory(_ txn: Transaction, budget: Budget) -> Bool {
        // Salary-Cycle-Budgets ohne Kategorien zählen alle Ausgaben der Periode.
        if budget.categoryIDs.isEmpty && budget.isSalaryCycle { return true }
        guard let categoryID = txn.categoryID else { return false }
        return budget.categoryIDs.contains(categoryID)
    }
}
