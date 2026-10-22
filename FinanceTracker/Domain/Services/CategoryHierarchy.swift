import Foundation

/// WP12: Category-Hierarchie-Semantik an einer Stelle.
///
/// Produktregel: Parent-Kategorien sind aggregation-only,
/// sobald Leaf-only-Kategorisierung gilt. Nur Leaves sind zuweisbar;
/// Parents ohne Kinder verhalten sich als wählbares Leaf.
///
/// Parent als FILTER ist erlaubt, aber Filter müssen auf alle
/// Descendants expandieren (`descendantIDs`).
struct CategoryHierarchy: Sendable {
    /// Alle Descendants einer Kategorie (inkl. der ID selbst), transitiv.
    func descendantIDs(of categoryID: UUID, in categories: [Category]) -> Set<UUID> {
        var result: Set<UUID> = [categoryID]
        var frontier: Set<UUID> = [categoryID]

        while !frontier.isEmpty {
            let children = Set(
                categories
                    .filter { category in
                        guard let parentID = category.parentID else { return false }
                        return frontier.contains(parentID)
                    }
                    .map(\.id)
            )
            let newIDs = children.subtracting(result)
            guard !newIDs.isEmpty else { break }
            result.formUnion(newIDs)
            frontier = newIDs
        }

        return result
    }

    /// Zuweisbare Kategorien: nur Leaves. Ein Parent ohne Kinder gilt als
    /// Leaf (aggregiert nichts anderes als sich selbst).
    func assignableCategories(in categories: [Category]) -> [Category] {
        let parentIDs = Set(categories.compactMap(\.parentID))
        return categories
            .filter { !parentIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Ob eine Kategorie als Transaktions-Kategorie zuweisbar ist.
    func isAssignable(_ categoryID: UUID, in categories: [Category]) -> Bool {
        let assignableIDs = Set(assignableCategories(in: categories).map(\.id))
        return assignableIDs.contains(categoryID)
    }
}
