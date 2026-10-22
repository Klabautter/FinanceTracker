import Foundation
import Testing

@testable import FinanceTracker

/// WP12: Leaf-only Assignability + Parent-Filter-Expansion.
@Suite("CategoryHierarchy")
struct CategoryHierarchyTests {

    private let hierarchy = CategoryHierarchy()
    typealias Category = FinanceTracker.Category

    private var fixture: [Category] {
        // Lebensmittel (Parent) → Supermarkt, Bäckerei (Leaves)
        // Haushalt (Leaf-Parent ohne Kinder → wählbar)
        // Miete (echtes Root-Leaf)
        [
            Category(id: Self.fixtureParent, name: "Lebensmittel", systemIconName: "cart"),
            Category(id: UUID(), name: "Supermarkt", systemIconName: "cart", colorToken: .gray, parentID: Self.fixtureParent),
            Category(id: UUID(), name: "Bäckerei", systemIconName: "birthday.cake", colorToken: .gray, parentID: Self.fixtureParent),
            Category(id: UUID(), name: "Haushalt", systemIconName: "house"),
            Category(id: UUID(), name: "Miete", systemIconName: "house.fill")
        ]
    }

    private static let fixtureParent = UUID() // Lebensmittel

    private var parentCategory: Category {
        fixture.first { $0.name == "Lebensmittel" }!
    }

    @Test("Parent ist nicht zuweisbar, Leaves schon")
    func assignability() {
        let categories = fixture
        let parent = categories.first { $0.name == "Lebensmittel" }!
        let leaf = categories.first { $0.name == "Supermarkt" }!

        #expect(!hierarchy.isAssignable(parent.id, in: categories))
        #expect(hierarchy.isAssignable(leaf.id, in: categories))
    }

    @Test("Parent ohne Kinder verhält sich als wählbares Leaf")
    func childlessParentAssignable() {
        let categories = fixture
        let household = categories.first { $0.name == "Haushalt" }!
        let rent = categories.first { $0.name == "Miete" }!
        #expect(hierarchy.isAssignable(household.id, in: categories))
        #expect(hierarchy.isAssignable(rent.id, in: categories))
    }

    @Test("assignableCategories enthält keine Parents mit Kindern")
    func assignableList() {
        let names = hierarchy.assignableCategories(in: fixture).map(\.name)
        #expect(!names.contains("Lebensmittel"))
        #expect(names.contains("Supermarkt"))
        #expect(names.contains("Bäckerei"))
        #expect(names.contains("Haushalt"))
        #expect(names.contains("Miete"))
    }

    @Test("Parent-Filter expandiert auf alle Descendants (inkl. self)")
    func descendantExpansion() {
        let categories = fixture
        let parent = categories.first { $0.name == "Lebensmittel" }!
        let supermarkt = categories.first { $0.name == "Supermarkt" }!
        let baeckerei = categories.first { $0.name == "Bäckerei" }!
        let descendants = hierarchy.descendantIDs(of: parent.id, in: categories)

        #expect(descendants.count == 3) // parent + 2 Kinder
        #expect(descendants.contains(parent.id))
        #expect(descendants.contains(supermarkt.id))
        #expect(descendants.contains(baeckerei.id))
    }

    @Test("Descendants sind transitiv (Enkel einschließen)")
    func transitiveDescendants() {
        // Tiefe Hierarchie: A → B → C
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let deep: [Category] = [
            Category(id: a, name: "A", systemIconName: "folder", colorToken: .gray),
            Category(id: b, name: "B", systemIconName: "folder", colorToken: .gray, parentID: a),
            Category(id: c, name: "C", systemIconName: "folder", colorToken: .gray, parentID: b)
        ]
        let descendants = hierarchy.descendantIDs(of: a, in: deep)
        #expect(descendants == Set([a, b, c]))
    }

    @Test("Leaf-Filter expandiert nur auf sich selbst")
    func leafExpansion() {
        let categories = fixture
        let leaf = categories.first { $0.name == "Supermarkt" }!
        #expect(hierarchy.descendantIDs(of: leaf.id, in: categories) == Set([leaf.id]))
    }
}

