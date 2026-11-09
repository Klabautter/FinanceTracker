import Foundation

enum DeleteCategoryError: Error, Equatable {
    /// Namen der Budgets, deren einzige Kategorie gelöscht würde.
    case onlyCategoryOfBudgets([String])
}

/// Löscht eine Kategorie, ohne dass ein Verweis auf sie zurückbleibt.
///
/// Buchungen, Splitzeilen, Fixkosten und Budgets wechseln zur Zielkategorie
/// (`reassignTo`); ohne Ziel werden sie „Ohne Kategorie" bzw. die Kategorie
/// verschwindet aus dem Budget. Regeln, die auf sie zielten, entfallen.
///
/// Ohne Ziel wird das Löschen abgelehnt, wenn ein Budget nur diese eine
/// Kategorie hat: Ein Budget ohne Kategorie zählt nichts mehr oder, im
/// Gehaltszyklus, plötzlich alle Ausgaben. Das entscheidet der Nutzer.
struct DeleteCategory: Sendable {
    let categoryRepository: any CategoryRepository
    let budgetRepository: any BudgetRepository

    func callAsFunction(_ categoryID: UUID, reassignTo newCategoryID: UUID?) async throws {
        if newCategoryID == nil {
            let emptied = try await budgetRepository.budgets()
                .filter { $0.categoryIDs == [categoryID] }
                .map(\.name)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            guard emptied.isEmpty else {
                throw DeleteCategoryError.onlyCategoryOfBudgets(emptied)
            }
        }
        try await categoryRepository.delete(id: categoryID, reassignTo: newCategoryID)
    }
}
