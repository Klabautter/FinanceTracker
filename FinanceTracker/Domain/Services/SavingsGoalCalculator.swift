import Foundation

/// P2 Sparziele (Sinking-Funds) auf bestehendem `Budget(accumulate)` +
/// `RecurringCommitment`, kein Parallelmodell (#11/#30).
///
/// Semantik:
/// - Gespart = `BudgetProgress.remaining` (effectiveLimit − spent, Floor 0).
///   Das ist der aktuell zurückgelegte Betrag in der Budget-Währung.
/// - Fortschritt = gespart / Zielbetrag (geklemmt 0...1).
/// - Fehlbetrag = max(0, Ziel − gespart), immer in der Budget-Währung
///   (#19/#35: keine Währungs-Mischung, Fremdwährung wird nicht addiert).
/// - Monatsrate = Fehlbetrag / volle Monate bis Zieldatum (aufrundungsfrei,
///   reine Division; kein Datum = nil).
/// - Forecast: Sparziele fließen über `remainingBudgetReservation` ein
///   (ForecastService reserviert den Rest jedes forecast-relevanten Budgets).
///   `plannedSavings` bleibt 0, keine Doppelzählung.
struct SavingsGoalProgress: Sendable, Hashable, Equatable {
    let budgetID: UUID
    let currency: CurrencyCode
    /// Aktuell zurückgelegt (Budget-Währung).
    let saved: Decimal
    let target: Decimal
    let targetDate: Date?
    /// Monate bis zum Zieldatum (volle Kalendermonate ab `now`).
    let monthsRemaining: Int?
    /// Benötigte Sparrate pro Monat (Budget-Währung), nil ohne Zieldatum.
    let requiredMonthly: Decimal?

    var fraction: Double {
        guard target > 0 else { return 0 }
        return max(0, min(1, NSDecimalNumber(decimal: saved / target).doubleValue))
    }

    var shortfall: Decimal { max(0, target - saved) }
    var isReached: Bool { saved >= target }
}

struct SavingsGoalCalculator: Sendable {
    /// Fortschritt eines Sparziels aus dem Budget-Progress.
    /// `progress.currency` == Budget-Währung; Zielbetrag gilt in derselben
    /// Währung (#19/#35). Ohne Zielbetrag → nil (kein Sparziel).
    func goalProgress(
        for progress: BudgetProgress,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SavingsGoalProgress? {
        guard let target = progress.budget.targetAmount, target > 0 else { return nil }
        let saved = progress.remaining
        let targetDate = progress.budget.targetDate
        var monthsRemaining: Int?
        var requiredMonthly: Decimal?
        if let targetDate {
            monthsRemaining = fullMonths(from: now, to: targetDate, calendar: calendar)
            if let months = monthsRemaining, months > 0 {
                requiredMonthly = max(0, target - saved) / Decimal(months)
            } else if let months = monthsRemaining, months <= 0 {
                // Zieldatum erreicht/überschritten: Fehlbetrag ist sofort fällig.
                requiredMonthly = max(0, target - saved)
            }
        }
        return SavingsGoalProgress(
            budgetID: progress.budget.id,
            currency: progress.currency,
            saved: saved,
            target: target,
            targetDate: targetDate,
            monthsRemaining: monthsRemaining,
            requiredMonthly: requiredMonthly
        )
    }

    private func fullMonths(from now: Date, to target: Date, calendar: Calendar) -> Int {
        let startMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        let targetMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: target))
        guard let startMonth, let targetMonth else { return 0 }
        return calendar.dateComponents([.month], from: startMonth, to: targetMonth).month ?? 0
    }
}
