import Foundation

@testable import FinanceTracker

/// Test-Helfer: Budget-Verbrauch für eine einzelne Periode, ohne Übertrag
/// und Gehaltszyklus. Rechnet über dieselbe `BudgetContributionCalculator`-
/// Pipeline wie die App (`LoadBudgetProgresses`), damit die Semantik-Tests
/// (Ausschluss, Umbuchung, Erstattung, Fremdwährung, Splits) den echten
/// Rechenweg prüfen. In der App selbst gibt es nur `LoadBudgetProgresses`.
struct BudgetCalculator: Sendable {
    /// Budget-Verbrauch über die GLEICHE effektive Finance-Semantik wie
    /// Analytics/Forecast (Roadmap #36):
    /// - `excludedFromAnalytics` → kein Verbrauch (#39)
    /// - Transfer (inkl. manualKindOverride) → kein Verbrauch (#38)
    /// - Refund → reduziert den Verbrauch
    /// - Fremdwährung → zum Kurs des übergebenen Converters in die
    ///   Budget-Währung umgerechnet (gleiche Semantik wie
    ///   Analytics). Der Converter stammt aus dem `FXRateProvider`-Snapshot
    ///   (live → 24h-Cache → statische Referenzkurse); Default ist der
    ///   statische Fallback. Ohne Kurs ausgeschlossen und über
    ///   `excludedCurrencies` gemeldet (§17).
    /// - Splits (#71): Transaktionen mit Split-Lines zählen über ihre
    ///   Split-Kategorien, der Parent wird nicht zusätzlich gezählt
    /// - Multi-Category (#100): Verbrauch über alle zugeordneten Kategorien
    func progress(
        budgets: [Budget],
        transactions: [Transaction],
        categories: [FinanceTracker.Category],
        monthInterval: DateInterval,
        calendar: Calendar = .current,
        baseCurrency: CurrencyCode = .eur,
        splitLines: [TransactionSplitLine] = [],
        amountHistory: [BudgetAmountHistory] = [],
        intervals: [UUID: DateInterval] = [:],
        converter: CurrencyConverter = CurrencyConverter()
    ) -> [BudgetProgress] {
        let contributionCalculator = BudgetContributionCalculator(converter: converter)

        return budgets
            .filter(\.enabled)
            .map { budget -> BudgetProgress in
                let budgetInterval = intervals[budget.id] ?? monthInterval

                // WP9: Der Verbrauch läuft über dieselbe Contribution-
                // Pipeline wie das Budget-Detail: Header und Trend-Ende
                // sind dadurch garantiert identisch.
                let contributionResult = contributionCalculator.result(
                    budget: budget,
                    transactions: transactions,
                    splitLines: splitLines,
                    period: budgetInterval,
                    calendar: calendar
                )
                let total = contributionCalculator.total(contributionResult.contributions)

                // History (Roadmap #99): gültiger Betrag = jüngster Eintrag
                // mit periodStart ≤ Perioden-Start; sonst aktueller Betrag.
                let historyLimit = amountHistory
                    .filter { $0.budgetID == budget.id && $0.periodStart <= budgetInterval.start }
                    .max { $0.periodStart < $1.periodStart }?
                    .amount

                return BudgetProgress(
                    budget: budget,
                    spent: total,
                    currency: budget.currency,
                    period: budgetInterval,
                    limitOverride: historyLimit,
                    excludedCurrencies: contributionResult.excludedCurrencies
                )
            }
            .sorted { $0.spent > $1.spent }
    }

    func totalLimit(progresses: [BudgetProgress]) -> Decimal {
        progresses.reduce(into: Decimal(0)) { partial, progress in
            partial += progress.effectiveLimit
        }
    }

    func totalSpent(progresses: [BudgetProgress]) -> Decimal {
        progresses.reduce(into: Decimal(0)) { partial, progress in
            partial += progress.spent
        }
    }
}
