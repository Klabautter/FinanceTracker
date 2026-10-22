import Foundation
import Testing

@testable import FinanceTracker

@Suite("CategorySuggestion")
struct CategorySuggestionTests {
    private func txn(
        id: UUID = UUID(),
        merchant: String,
        merchantID: UUID? = nil,
        categoryID: UUID? = nil
    ) -> Transaction {
        Transaction(
            id: id,
            accountID: UUID(),
            source: .manual,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -10, currency: .eur),
            bookedAt: Date(),
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantID: merchantID,
            merchantDisplayName: merchant,
            categoryID: categoryID
        )
    }

    private var categories: [FinanceTracker.Category] {
        let food = Category(name: "Lebensmittel", systemIconName: "cart")
        let mobility = Category(name: "Mobilität", systemIconName: "car")
        return [food, mobility]
    }

    @Test("Modus des Verlaufs wird vorgeschlagen (Filialnummern egal)")
    func modeIsSuggested() {
        let cats = categories
        let foodID = cats[0].id
        let history = [
            txn(merchant: "REWE 111", categoryID: foodID),
            txn(merchant: "REWE 222", categoryID: foodID),
            txn(merchant: "REWE Markt", categoryID: cats[1].id),
        ]
        let open = txn(merchant: "REWE 999")
        let result = CategorySuggestionService().suggestions(
            uncategorized: [open], history: history, categories: cats
        )
        // „REWE 111/222/999“ → Lernregel merchantContains(REWE) = 2 Stimmen,
        // „REWE Markt“ → merchantContains(REWE MARKT) trifft „REWE 999“ nicht.
        #expect(result[open.id] == CategorySuggestion(categoryID: foodID, supportCount: 2))
    }

    @Test("Ohne Verlauf kein Vorschlag")
    func noHistoryNoSuggestion() {
        let open = txn(merchant: "REWE 999")
        let result = CategorySuggestionService().suggestions(
            uncategorized: [open], history: [], categories: categories
        )
        #expect(result.isEmpty)
    }

    @Test("Unbekannter Händler bekommt keinen Vorschlag")
    func unknownMerchantNoSuggestion() {
        let cats = categories
        let history = [txn(merchant: "REWE", categoryID: cats[0].id)]
        let open = txn(merchant: "ALDI Nord")
        let result = CategorySuggestionService().suggestions(
            uncategorized: [open], history: history, categories: cats
        )
        #expect(result.isEmpty)
    }

    @Test("Parent-Kategorie wird nie vorgeschlagen (Leaf-only)")
    func parentNeverSuggested() {
        let parent = Category(name: "Essen", systemIconName: "fork.knife")
        var child = Category(name: "Restaurant", systemIconName: "fork.knife")
        child.parentID = parent.id
        let history = [txn(merchant: "REWE", categoryID: parent.id)]
        let open = txn(merchant: "REWE Filiale")
        let result = CategorySuggestionService().suggestions(
            uncategorized: [open], history: history, categories: [parent, child]
        )
        #expect(result.isEmpty, "Parent ist aggregation-only und nicht zuweisbar")
    }

    @Test("Gleichstand deterministisch gebrochen")
    func tieBrokenDeterministically() {
        let cats = categories
        let history = [
            txn(merchant: "REWE", categoryID: cats[0].id),
            txn(merchant: "REWE Filiale", categoryID: cats[1].id),
        ]
        // „REWE Filiale 7“ trifft beide Lernregeln (REWE + REWE FILIALE).
        let open = txn(merchant: "REWE Filiale 7")
        let first = CategorySuggestionService().suggestions(
            uncategorized: [open], history: history, categories: cats
        )
        let second = CategorySuggestionService().suggestions(
            uncategorized: [open], history: history.reversed(), categories: cats
        )
        #expect(first == second)
        #expect(first[open.id]?.supportCount == 1)
    }

    @Test("Händler-ID gruppiert stärker als Name")
    func merchantIDGroups() {
        let cats = categories
        let merchantID = UUID()
        let history = [txn(merchant: "Umbenannter Markt", merchantID: merchantID, categoryID: cats[1].id)]
        let open = txn(merchant: "Ganz anderer Name", merchantID: merchantID)
        let result = CategorySuggestionService().suggestions(
            uncategorized: [open], history: history, categories: cats
        )
        #expect(result[open.id]?.categoryID == cats[1].id)
    }

    @Test("Vorschlag verspricht nur, was die Merkregel hält")
    func suggestionMatchesRuleSemantics() {
        let cats = categories
        let history = [txn(merchant: "REWE 111", categoryID: cats[0].id)]
        let open = txn(merchant: "REWE 999")
        let service = CategorySuggestionService()
        let result = service.suggestions(uncategorized: [open], history: history, categories: cats)
        #expect(result[open.id] != nil)
        // Dieselbe Lernregel, die der Vorschlag zählt, feuert für die offene
        // Buchung, der Scope-.merchant-Pfad im Model hält das Versprechen.
        let rule = CategoryRule.makeFromCorrection(
            transaction: history[0], categoryID: cats[0].id, existingRules: []
        )
        #expect(rule != nil)
        #expect(CategoryRuleEngine().firstMatch(in: [rule!], for: open) != nil)
    }
}
