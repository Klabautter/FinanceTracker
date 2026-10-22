import Foundation
import Testing

@testable import FinanceTracker

@Suite("CategoryRuleEngine")
struct CategoryRuleEngineTests {
    private let engine = CategoryRuleEngine()
    private let groceries = Category(name: "Lebensmittel", systemIconName: "cart")
    private let restaurants = Category(name: "Restaurants", systemIconName: "fork.knife")

    private func txn(
        merchant: String,
        description: String? = nil,
        amount: Decimal = -10
    ) -> Transaction {
        Transaction(
            accountID: UUID(),
            source: .etherFiCashCSV,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: Date(),
            rawDescription: description ?? merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
    }

    @Test("merchantContains matcht case- und whitespace-insensitiv")
    func merchantContains() {
        let rules = [CategoryRule(priority: 1, condition: .merchantContains("mcdonalds"), categoryID: restaurants.id)]

        var transaction = txn(merchant: "MCDONALDS 155")
        #expect(engine.apply(rules, to: &transaction))
        #expect(transaction.categoryID == restaurants.id)
    }

    @Test("Merchant-Matching respektiert Token-Grenzen")
    func merchantContainsUsesTokenBoundaries() {
        let rules = [
            CategoryRule(priority: 1, condition: .merchantContains("SPAR"), categoryID: groceries.id),
            CategoryRule(priority: 2, condition: .merchantContains("UBER"), categoryID: restaurants.id)
        ]

        #expect(engine.firstMatch(in: rules, for: txn(merchant: "SPARKASSE MUENCHEN")) == nil)
        #expect(engine.firstMatch(in: rules, for: txn(merchant: "ÜBERWEISUNG MIETE")) == nil)
        #expect(engine.firstMatch(in: rules, for: txn(merchant: "SPAR MARKT 12"))?.categoryID == groceries.id)
        #expect(engine.firstMatch(in: rules, for: txn(merchant: "UBER TRIP"))?.categoryID == restaurants.id)
    }

    @Test("Lieferdienste zählen zu Restaurants, auch wenn die Kartenbranche Lebensmittel meldet")
    func deliveryServicesAreRestaurants() {
        let rules = CategoryRule.defaultCatalog()
        for merchant in ["Foodora AT Foodora_AT_taz", "UBER EATS", "Mjam Wien"] {
            #expect(engine.firstMatch(in: rules, for: txn(merchant: merchant))?.categoryID == Category.restaurants.id)
        }
    }

    @Test("Systemkatalog trifft kanonische SPAR-, Apple-, dm- und McDonald's-Namen")
    func systemCatalogMatchesCanonicalMerchants() throws {
        let normalizer = MerchantNormalizer()
        let rules = CategoryRule.defaultCatalog()
        let cases: [(String, UUID)] = [
            ("SPAR MARKT 12", Category.groceries.id),
            ("APPLE.COM/BILL 123", Category.subscriptions.id),
            ("dm drogerie 55", Category.health.id),
            ("MCDONALDS 155", Category.restaurants.id)
        ]

        for (raw, expectedCategoryID) in cases {
            let canonical = try #require(normalizer.canonicalDisplayName(from: raw))
            #expect(engine.firstMatch(in: rules, for: txn(merchant: canonical))?.categoryID == expectedCategoryID)
        }
    }

    @Test("Systemkatalog deckt sichere Enable-Banking-Mock-Händler ab")
    func systemCatalogMatchesSafeBankMerchants() {
        let rules = CategoryRule.defaultCatalog()
        let cases: [(String, String, UUID)] = [
            ("Restaurant", "Restaurant", Category.restaurants.id),
            ("Hotel", "Hotel", Category.travel.id),
            ("Adobe", "Adobe Creative Cloud", Category.subscriptions.id),
            ("MediaMarkt", "Kartenzahlung", Category.shopping.id),
            ("Vapiano", "Vapiano", Category.restaurants.id),
            ("Bolt", "Bolt Fahrt", Category.taxi.id),
            ("Fitinn", "Mitgliedsbeitrag", Category.health.id),
            ("Magenta Telekom", "Mobilfunk", Category.subscriptions.id),
            ("Wien Energie", "Strom/Gas", Category.utilities.id),
            ("ÖBB", "ÖBB Ticket", Category.travel.id),
            ("OMV", "OMV", Category.fuel.id),
            ("Bankomat Salzburg", "Bargeldbehebung", Category.cash.id)
        ]

        for (merchant, description, expectedCategoryID) in cases {
            #expect(
                engine.firstMatch(
                    in: rules,
                    for: txn(merchant: merchant, description: description)
                )?.categoryID == expectedCategoryID
            )
        }

        #expect(
            engine.firstMatch(in: rules, for: txn(merchant: "Müller", description: "Müller")) == nil,
            "Ein häufiger Nachname bleibt ohne eindeutigen Kontext bewusst prüfbar"
        )
        #expect(
            engine.firstMatch(
                in: rules,
                for: txn(merchant: "Bank", description: "Zinsgutschrift Habenzinsen", amount: 12)
            )?.categoryID == Category.income.id
        )
        #expect(
            engine.firstMatch(
                in: rules,
                for: txn(merchant: "Bank", description: "Zinsgutschrift Korrektur", amount: -12)
            ) == nil,
            "Zinsregeln dürfen Ausgaben nicht als Einnahmen maskieren"
        )
    }

    @Test("Niedrigste Priorität gewinnt (first match)")
    func priorityOrdering() {
        let rules = [
            CategoryRule(priority: 50, condition: .merchantContains("SPAR"), categoryID: groceries.id),
            CategoryRule(priority: 10, condition: .merchantContains("SPAR DANKT"), categoryID: groceries.id),
            CategoryRule(priority: 30, condition: .merchantEquals("SPAR DANKT 4161"), categoryID: restaurants.id)
        ]

        let match = engine.firstMatch(in: rules, for: txn(merchant: "SPAR DANKT 4161"))
        #expect(match?.priority == 10)
    }

    @Test("Deaktivierte Regeln werden ignoriert")
    func disabledRulesIgnored() {
        let rules = [
            CategoryRule(priority: 1, condition: .merchantContains("REWE"), categoryID: groceries.id, enabled: false)
        ]
        var transaction = txn(merchant: "REWE SAGT DANKE")

        #expect(!engine.apply(rules, to: &transaction))
        #expect(transaction.categoryID == nil)
    }

    @Test("Bestehende Kategorie wird nicht überschrieben")
    func doesNotOverrideExistingCategory() {
        let rules = [CategoryRule(priority: 1, condition: .merchantContains("REWE"), categoryID: groceries.id)]
        var transaction = txn(merchant: "REWE")
        transaction.categoryID = restaurants.id

        #expect(!engine.apply(rules, to: &transaction))
        #expect(transaction.categoryID == restaurants.id)
    }

    @Test("descriptionContains greift auf Rohbeschreibung zu")
    func descriptionCondition() {
        let rules = [CategoryRule(priority: 1, condition: .descriptionContains("APOTHEKE"), categoryID: restaurants.id)]
        let transaction = txn(merchant: "SHOP APOTHEKE EU", description: "SHOP APOTHEKE EU 48211")

        #expect(engine.firstMatch(in: rules, for: transaction) != nil)
    }

    @Test("Signumsichere Beschreibungsregeln unterscheiden Einnahme und Ausgabe")
    func signedDescriptionConditions() {
        let incomeID = UUID()
        let rentID = UUID()
        let rules = [
            CategoryRule(priority: 1, condition: .descriptionContainsCredit("GEHALT"), categoryID: incomeID),
            CategoryRule(priority: 2, condition: .descriptionContainsCredit("LOHN"), categoryID: incomeID),
            CategoryRule(priority: 3, condition: .descriptionContainsDebit("MIETE"), categoryID: rentID)
        ]

        #expect(engine.firstMatch(in: rules, for: txn(merchant: "Arbeitgeber", description: "GEHALT AUGUST", amount: 2_500))?.categoryID == incomeID)
        #expect(engine.firstMatch(in: rules, for: txn(merchant: "Vermieter", description: "MIETE AUGUST", amount: -900))?.categoryID == rentID)
        #expect(engine.firstMatch(in: rules, for: txn(merchant: "Vermieter", description: "MIETE RÜCKZAHLUNG", amount: 900)) == nil)
        #expect(engine.firstMatch(in: rules, for: txn(merchant: "Arbeitgeber", description: "GEHALT KORREKTUR", amount: -100)) == nil)
    }

    @Test("Vorkompilierte Regeln sind wiederverwendbar und semantisch identisch")
    func compiledRulesMatchAllConditionKinds() {
        let merchantID = UUID()
        let targetID = UUID()
        let cases: [(CategoryRule, Transaction)] = [
            (
                CategoryRule(priority: 1, condition: .merchantEquals("Café Central"), categoryID: targetID),
                txn(merchant: "CAFÉ CENTRAL")
            ),
            (
                CategoryRule(priority: 1, condition: .merchantContains("SPAR MARKT"), categoryID: targetID),
                txn(merchant: "SPAR MARKT 12")
            ),
            (
                CategoryRule(priority: 1, condition: .descriptionContains("MONATS TICKET"), categoryID: targetID),
                txn(merchant: "ÖPNV", description: "Monats-Ticket Wien")
            ),
            (
                CategoryRule(priority: 1, condition: .descriptionContainsDebit("MIETE"), categoryID: targetID),
                txn(merchant: "Vermieter", description: "Miete September", amount: -900)
            ),
            (
                CategoryRule(priority: 1, condition: .descriptionContainsCredit("GEHALT"), categoryID: targetID),
                txn(merchant: "Arbeitgeber", description: "Gehalt September", amount: 2_500)
            ),
            (
                CategoryRule(priority: 1, condition: .merchantIDEquals(merchantID), categoryID: targetID),
                {
                    var transaction = txn(merchant: "Identifizierter Händler")
                    transaction.merchantID = merchantID
                    return transaction
                }()
            )
        ]

        for (rule, transaction) in cases {
            let compiled = engine.compile([rule], assignableCategoryIDs: [targetID])
            #expect(compiled.firstMatch(for: transaction)?.id == rule.id)

            var first = transaction
            var second = transaction
            #expect(compiled.apply(to: &first))
            #expect(compiled.apply(to: &second))
            #expect(first.categoryID == targetID)
            #expect(second.categoryID == targetID)
        }
    }

    @Test("Nur zuweisbare Leaf-Ziele werden angewandt")
    func onlyAssignableTargetsApply() {
        let categories = Category.defaultCatalog()
        let assignableIDs = Set(CategoryHierarchy().assignableCategories(in: categories).map(\.id))
        let parentRule = CategoryRule(
            priority: 1,
            condition: .merchantContains("REWE"),
            categoryID: Category.food.id
        )
        var transaction = txn(merchant: "REWE")

        #expect(!engine.apply([parentRule], assignableCategoryIDs: assignableIDs, to: &transaction))
        #expect(transaction.categoryID == nil)
    }

    @Test("User-Regeln haben Vorrang vor System-Regeln")
    func userRulesOverrideSystemRules() {
        let system = CategoryRule(
            priority: 1,
            condition: .merchantContains("AMAZON"),
            categoryID: groceries.id,
            origin: .system
        )
        let user = CategoryRule(
            priority: 500,
            condition: .merchantContains("AMAZON"),
            categoryID: restaurants.id,
            origin: .user
        )

        var transaction = txn(merchant: "AMZN MKTP DE AMAZON")
        engine.apply([system, user], to: &transaction)

        #expect(transaction.categoryID == restaurants.id)
    }

    @Test("Regel aus Korrektur entfernt variable Ziffern-Tokens")
    func correctionStripsVariableTokens() {
        let rule = CategoryRule.makeFromCorrection(
            transaction: txn(merchant: "REWE SAGT DANKE 832741 MUENCHEN"),
            categoryID: groceries.id,
            existingRules: []
        )

        #expect(rule?.condition == .merchantContains("REWE SAGT DANKE MUENCHEN"))
    }

    @Test("Regel aus Korrektur: enthält Händler und gewinnt vor älteren User-Regeln")
    func makeFromCorrection() {
        let existing = [CategoryRule(priority: 7, condition: .merchantContains("X"), categoryID: groceries.id)]
        let rule = CategoryRule.makeFromCorrection(
            transaction: txn(merchant: "Uber Trip"),
            categoryID: restaurants.id,
            existingRules: existing
        )

        #expect(rule?.condition == .merchantContains("Uber Trip"))
        #expect(rule?.priority == 6)

        #expect(CategoryRule.makeFromCorrection(
            transaction: txn(merchant: "Unbekannt"),
            categoryID: groceries.id,
            existingRules: []
        ) == nil)
    }

    @Test("Neue Korrektur desselben Lernschlüssels aktualisiert die User-Regel")
    func correctionReplacesConflictingUserRule() throws {
        let merchantID = UUID()
        var transaction = txn(merchant: "Apple")
        transaction.merchantID = merchantID
        let existing = CategoryRule(
            id: UUID(),
            priority: 42,
            condition: .merchantIDEquals(merchantID),
            categoryID: groceries.id,
            enabled: false,
            origin: .user
        )

        let replacement = try #require(CategoryRule.makeFromCorrection(
            transaction: transaction,
            categoryID: restaurants.id,
            existingRules: [existing]
        ))

        #expect(replacement.id == existing.id)
        #expect(replacement.priority == existing.priority)
        #expect(replacement.categoryID == restaurants.id)
        #expect(replacement.enabled)
    }
}

@Suite("CategoryRulePersistence")
struct CategoryRulePersistenceTests {
    @Test("Regeln werden persistiert, gemappt und gelöscht")
    func roundtrip() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        let categoryID = UUID()
        let rules = [
            CategoryRule(priority: 5, condition: .merchantContains("REWE"), categoryID: categoryID),
            CategoryRule(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C0")!, priority: 9,
                         condition: .descriptionContains("GEHALT"), categoryID: UUID(), enabled: false),
            CategoryRule(priority: 10, condition: .descriptionContainsDebit("MIETE"), categoryID: UUID()),
            CategoryRule(priority: 11, condition: .descriptionContainsCredit("LOHN"), categoryID: UUID())
        ]

        try await dependencies.ruleRepository.upsert(rules)
        #expect(try await dependencies.ruleRepository.rules().count == 4)

        let loadedContains = try await dependencies.ruleRepository.rules().first { $0.priority == 5 }
        #expect(loadedContains?.condition == .merchantContains("REWE"))
        #expect(loadedContains?.enabled == true)

        if var toggleTarget = try await dependencies.ruleRepository.rules().first(where: { $0.priority == 9 }) {
            toggleTarget.enabled = true
            try await dependencies.ruleRepository.upsert([toggleTarget])
        }
        let toggled = try await dependencies.ruleRepository.rules().first { $0.priority == 9 }
        #expect(toggled?.enabled == true)

        if let id = loadedContains?.id {
            try await dependencies.ruleRepository.delete(id: id)
        }
        let persisted = try await dependencies.ruleRepository.rules()
        #expect(persisted.count == 3)
        #expect(persisted.contains { $0.condition == .descriptionContainsDebit("MIETE") })
        #expect(persisted.contains { $0.condition == .descriptionContainsCredit("LOHN") })
    }

    @Test("Default-Katalog ist priorisiert und eindeutig")
    func defaultCatalogSanity() {
        let catalog = CategoryRule.defaultCatalog()
        #expect(catalog.count >= 20)
        #expect(Set(catalog.map(\.id)).count == catalog.count)
        #expect(catalog.allSatisfy { $0.enabled })
    }
}
