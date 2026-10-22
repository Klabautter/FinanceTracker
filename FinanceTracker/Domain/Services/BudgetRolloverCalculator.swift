import Foundation

/// WP10: Echtes Budget-Rollover.
///
/// Policy (dokumentiert):
/// - `.accumulate`: Nicht verbrauchter Rest der Vorperiode wird übertragen:
///   `previousLimit + incomingCarry − previousSpent`. Bei Überbudget wird der
///   Carry auf 0 geklemmt (Floor-0): Für Rücklagen-Budgets ist die
///   Übertragung von Schulden in den Folgemonat nicht sinnvoll.
/// - `.reset`: Kein Rollover, jede Periode startet bei 0.
///
/// History-aware: Das Vorperioden-Limit kommt aus `BudgetAmountHistory`
/// (jüngster Eintrag mit periodStart ≤ Vorperioden-Start), nie das
/// heutige Limit rückwirkend.
struct BudgetRolloverCalculator: Sendable {
    /// Carry aus der Vorperiode. `0` bei `.reset`.
    ///
    /// - Parameters:
    ///   - previousSpent: Verbrauch der Vorperiode über die gemeinsame
    ///     Budget-Contribution-Pipeline (WP9): identische Semantik wie der
    ///     reguläre Progress.
    func carriedOver(
        budget: Budget,
        previousInterval: DateInterval,
        previousSpent: Decimal,
        incomingCarry: Decimal = 0,
        amountHistory: [BudgetAmountHistory]
    ) -> Decimal {
        guard budget.rolloverPolicy == .accumulate else { return 0 }

        // History-aware: Limit der Vorperiode (§83).
        let previousLimit = amountHistory
            .filter { $0.budgetID == budget.id && $0.periodStart <= previousInterval.start }
            .max { $0.periodStart < $1.periodStart }?
            .amount ?? budget.amount

        // Floor-0-Policy: Überbudget wird nicht als negativer Carry
        // weitergeschleppt.
        return max(0, previousLimit + incomingCarry - previousSpent)
    }
}
