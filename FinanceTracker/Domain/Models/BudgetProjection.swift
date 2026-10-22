import Foundation

extension BudgetProgress {
    /// Linearer Prognose-Wert für den Monatsverlauf (Roadmap #101):
    /// `spent / verstrichene Tage × Gesamttage`. Nur sinnvoll ab Tag 1.
    static func projectedMonthEndSpent(
        spent: Decimal,
        elapsedDays: Int,
        totalDaysInMonth: Int
    ) -> Decimal {
        guard elapsedDays > 0, totalDaysInMonth > 0 else { return spent }
        let projected = NSDecimalNumber(decimal: spent / Decimal(elapsedDays) * Decimal(totalDaysInMonth))
            .rounding(accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 2,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            ))
        return projected.decimalValue
    }
}
