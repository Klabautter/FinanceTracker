import Foundation

/// Budget-History (Roadmap #99): Gültiger Betrag pro Perioden-Start.
/// Rückwirkende Änderungen alter Perioden sind ausgeschlossen: der
/// Calculator löst den Betrag für einen Monat über den jüngsten Eintrag
/// mit `periodStart <= Monatsstart` auf.
struct BudgetAmountHistory: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let budgetID: UUID
    /// Start der Periode, für die dieser Betrag gilt.
    var periodStart: Date
    var amount: Decimal
    var currency: CurrencyCode

    init(id: UUID = UUID(), budgetID: UUID, periodStart: Date, amount: Decimal, currency: CurrencyCode = .eur) {
        self.id = id
        self.budgetID = budgetID
        self.periodStart = periodStart
        self.amount = amount
        self.currency = currency
    }
}
