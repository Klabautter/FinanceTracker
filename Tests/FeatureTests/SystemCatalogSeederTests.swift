import Foundation
import Testing

@testable import FinanceTracker

/// MacUX-Automatisierung: System-Katalog (Standardkategorien + Händler-
/// Regeln) für jede Installation, idempotentes Seeding, einmaliger
/// Rückfill offener Buchungen, User-Regeln und -Entscheidungen gewinnen.
@MainActor
@Suite("SystemCatalogSeeder")
struct SystemCatalogSeederTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SystemCatalogSeederTests-\(UUID().uuidString)")!
    }

    private func insertTransaction(
        _ dependencies: AppDependencies,
        accountID: UUID,
        merchant: String,
        categoryID: UUID? = nil
    ) async throws -> Transaction {
        var txn = Transaction(
            id: UUID(),
            accountID: accountID,
            source: .openBanking,
            externalID: "cat-\(UUID().uuidString)",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(10), currency: .eur),
            bookedAt: Date(),
            rawDescription: "\(merchant) Zahlung",
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
        txn.categoryID = categoryID
        try await dependencies.transactionRepository.upsert([txn])
        return txn
    }

    private func makeAccount(_ dependencies: AppDependencies) async throws -> Account {
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        ])
        return try #require(await dependencies.accountRepository.accounts().first)
    }

    @Test("Katalog wird geseedet, Rückfill kategorisiert nur offene positive Treffer")
    func seedBackfillsUncategorizedOnly() async throws {
        let dependencies = try makeDependencies()
        let defaults = makeDefaults()
        let account = try await makeAccount(dependencies)

        let rewe = try await insertTransaction(dependencies, accountID: account.id, merchant: "REWE MARKT 1234")
        let mystery = try await insertTransaction(dependencies, accountID: account.id, merchant: "Mystery Shop 42")
        let ownCategory = Category(name: "Eigen", systemIconName: "tag")
        try await dependencies.categoryRepository.upsert([ownCategory])
        let alreadyCategorized = try await insertTransaction(
            dependencies, accountID: account.id, merchant: "REWE MARKT 1234", categoryID: ownCategory.id
        )

        await SystemCatalogSeeder(dependencies: dependencies, defaults: defaults).seedIfNeeded()

        #expect(try await dependencies.categoryRepository.categories().count >= Category.defaultCatalog().count)
        #expect(try await dependencies.ruleRepository.rules().count >= CategoryRule.defaultCatalog().count)
        #expect(defaults.integer(forKey: SystemCatalogSeeder.defaultsKey) == SystemCatalogSeeder.catalogVersion)

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        let groceriesID = Category.groceries.id
        #expect(storedByID[rewe.id]?.categoryID == groceriesID, "REWE wird per System-Regel kategorisiert")
        #expect(storedByID[mystery.id]?.categoryID == nil, "Kein Treffer → kein stiller Fallback")
        #expect(storedByID[alreadyCategorized.id]?.categoryID == ownCategory.id, "Bestehende Kategorie bleibt")
    }

    @Test("Typ-Rückfill leitet Unbekannt aus dem Betragssignal ab, explizite Typen bleiben")
    func backfillInfersUnknownKinds() async throws {
        let dependencies = try makeDependencies()
        let defaults = makeDefaults()
        let account = try await makeAccount(dependencies)

        var unknownExpense = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .openBanking,
            externalID: "kind-bf-out",
            status: .booked,
            kind: .unknown,
            amount: Money(amount: -42.50, currency: .eur),
            bookedAt: Date(),
            rawDescription: "REWE MARKT 1234",
            rawMerchantName: "REWE MARKT 1234"
        )
        unknownExpense.categoryID = Category.groceries.id
        var unknownIncome = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .openBanking,
            externalID: "kind-bf-in",
            status: .booked,
            kind: .unknown,
            amount: Money(amount: 2850, currency: .eur),
            bookedAt: Date(),
            rawDescription: "GEHALT AUGUST",
            rawMerchantName: "Musterfirma GmbH"
        )
        unknownIncome.categoryID = Category.income.id
        let explicitTransfer = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .openBanking,
            externalID: "kind-bf-transfer",
            status: .booked,
            kind: .transfer,
            amount: Money(amount: 500, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Umbuchung Spar",
            rawMerchantName: "Umbuchung Spar"
        )
        try await dependencies.transactionRepository.upsert([unknownExpense, unknownIncome, explicitTransfer])

        await SystemCatalogSeeder(dependencies: dependencies, defaults: defaults).seedIfNeeded()

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        #expect(storedByID[unknownExpense.id]?.kind == .purchase)
        #expect(storedByID[unknownIncome.id]?.kind == .income)
        #expect(storedByID[explicitTransfer.id]?.kind == .transfer, "Explizite Typen werden nicht überschrieben")
    }

    @Test("Rückfill normalisiert sichere Eigenüberträge, User-Kategorie gewinnt")
    func backfillStrongTransfersWithoutOverridingUserCategory() async throws {
        let dependencies = try makeDependencies()
        let defaults = makeDefaults()
        let account = try await makeAccount(dependencies)

        let savings = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .openBanking,
            externalID: "transfer-savings",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -400, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Sparrate 08/2026",
            rawMerchantName: "Eigenes Tagesgeld",
            merchantDisplayName: "Eigenes Tagesgeld"
        )
        let customCategory = Category(name: "Eigene Entscheidung", systemIconName: "person.crop.circle")
        try await dependencies.categoryRepository.upsert([customCategory])
        var userClassified = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .openBanking,
            externalID: "transfer-user-choice",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -650, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Umbuchung Urlaub",
            rawMerchantName: "Eigenes Girokonto",
            merchantDisplayName: "Eigenes Girokonto"
        )
        userClassified.categoryID = customCategory.id
        try await dependencies.transactionRepository.upsert([savings, userClassified])

        await SystemCatalogSeeder(dependencies: dependencies, defaults: defaults).seedIfNeeded()

        let storedSavings = try #require(await dependencies.transactionRepository.transaction(id: savings.id))
        #expect(storedSavings.categoryID == Category.transfers.id)
        #expect(storedSavings.kind == .transfer)

        let storedUserChoice = try #require(await dependencies.transactionRepository.transaction(id: userClassified.id))
        #expect(storedUserChoice.categoryID == customCategory.id)
        #expect(storedUserChoice.kind == .purchase)
    }

    @Test("User-Regel schlägt System-Katalog")
    func userRuleWinsOverSystemCatalog() async throws {
        let dependencies = try makeDependencies()
        let defaults = makeDefaults()
        let account = try await makeAccount(dependencies)

        let restaurantsID = Category.restaurants.id
        try await dependencies.ruleRepository.upsert([
            CategoryRule(
                priority: 1,
                condition: .merchantContains("REWE"),
                categoryID: restaurantsID,
                origin: .user
            )
        ])
        let rewe = try await insertTransaction(dependencies, accountID: account.id, merchant: "REWE MARKT 1234")

        await SystemCatalogSeeder(dependencies: dependencies, defaults: defaults).seedIfNeeded()

        let stored = try #require(await dependencies.transactionRepository.transaction(id: rewe.id))
        #expect(stored.categoryID == restaurantsID)
    }

    @Test("Deaktivierte System-Regel bleibt deaktiviert")
    func disabledSystemRuleStaysDisabled() async throws {
        let dependencies = try makeDependencies()
        let defaults = makeDefaults()
        let account = try await makeAccount(dependencies)

        // Deaktivierung VOR dem ersten Seed, der Seeder übernimmt den
        // `enabled`-Zustand beim Idempotenz-Upsert.
        let reweRule = try #require(
            CategoryRule.defaultCatalog().first { $0.condition == .merchantContains("REWE") }
        )
        var disabled = reweRule
        disabled.enabled = false
        try await dependencies.ruleRepository.upsert([disabled])

        let rewe = try await insertTransaction(dependencies, accountID: account.id, merchant: "REWE MARKT 1234")

        await SystemCatalogSeeder(dependencies: dependencies, defaults: defaults).seedIfNeeded()

        let storedRule = try #require(await dependencies.ruleRepository.rules().first { $0.id == reweRule.id })
        #expect(storedRule.enabled == false)

        let storedTxn = try #require(await dependencies.transactionRepository.transaction(id: rewe.id))
        #expect(storedTxn.categoryID == nil, "Deaktivierte Regel kategorisiert nicht")

        // Versions-Bump simulieren → Re-Seed überschreibt `enabled` NICHT.
        defaults.set(0, forKey: SystemCatalogSeeder.defaultsKey)
        await SystemCatalogSeeder(dependencies: dependencies, defaults: defaults).seedIfNeeded()

        let reSeededRule = try #require(await dependencies.ruleRepository.rules().first { $0.id == reweRule.id })
        #expect(reSeededRule.enabled == false)
        let reSeededTxn = try #require(await dependencies.transactionRepository.transaction(id: rewe.id))
        #expect(reSeededTxn.categoryID == nil)
    }

    @Test("Nach Reset (leere Regeln) wird der Katalog neu geseedet")
    func reseedAfterWipe() async throws {
        let dependencies = try makeDependencies()
        let defaults = makeDefaults()

        await SystemCatalogSeeder(dependencies: dependencies, defaults: defaults).seedIfNeeded()
        try await LocalDataResetService(dependencies: dependencies).wipe()
        #expect(try await dependencies.ruleRepository.rules().isEmpty)

        await SystemCatalogSeeder(dependencies: dependencies, defaults: defaults).seedIfNeeded()
        #expect(try await dependencies.ruleRepository.rules().count >= CategoryRule.defaultCatalog().count)
        #expect(try await dependencies.categoryRepository.categories().count >= Category.defaultCatalog().count)
    }

    @Test("Aktuelle Version repariert fehlende stabile Regeln und signalisiert die Änderung")
    func repairsMissingStableRuleAtCurrentVersion() async throws {
        let dependencies = try makeDependencies()
        let defaults = makeDefaults()
        let seeder = SystemCatalogSeeder(dependencies: dependencies, defaults: defaults)
        await seeder.seedIfNeeded()
        let missingRule = try #require(await dependencies.ruleRepository.rules().first { $0.origin == .system })
        try await dependencies.ruleRepository.delete(id: missingRule.id)
        defaults.set(SystemCatalogSeeder.catalogVersion, forKey: SystemCatalogSeeder.defaultsKey)
        let revisionBefore = dependencies.changeTracker.revision

        await seeder.seedIfNeeded()

        #expect(try await dependencies.ruleRepository.rule(id: missingRule.id) != nil)
        #expect(dependencies.changeTracker.revision == revisionBefore + 1)
    }

    @Test("Migration deaktiviert unsichere Legacy-Regeln und installiert signumsichere Regeln")
    func migratesUnsafeLegacyDescriptionRules() async throws {
        let dependencies = try makeDependencies()
        let defaults = makeDefaults()
        let legacy = CategoryRule(
            priority: 1,
            condition: .merchantContains("GEHALT"),
            categoryID: Category.income.id,
            origin: .system
        )
        try await dependencies.ruleRepository.upsert([legacy])

        await SystemCatalogSeeder(dependencies: dependencies, defaults: defaults).seedIfNeeded()

        let rules = try await dependencies.ruleRepository.rules()
        #expect(rules.first { $0.id == legacy.id }?.enabled == false)
        #expect(rules.contains { $0.condition == .descriptionContainsCredit("GEHALT") && $0.enabled })
        #expect(rules.contains { $0.condition == .descriptionContainsDebit("MIETE") && $0.enabled })
    }

    @Test("Migration deaktiviert semantische Legacy-Duplikate")
    func disablesSemanticLegacyDuplicates() async throws {
        let dependencies = try makeDependencies()
        let defaults = makeDefaults()
        let stable = try #require(
            CategoryRule.defaultCatalog().first { $0.condition == .merchantContains("REWE") }
        )
        let legacy = CategoryRule(
            id: UUID(),
            priority: stable.priority,
            condition: stable.condition,
            categoryID: stable.categoryID,
            origin: .system
        )
        try await dependencies.ruleRepository.upsert([legacy])

        await SystemCatalogSeeder(dependencies: dependencies, defaults: defaults).seedIfNeeded()

        let rules = try await dependencies.ruleRepository.rules()
        #expect(rules.first { $0.id == stable.id }?.enabled == true)
        #expect(rules.first { $0.id == legacy.id }?.enabled == false)
    }
}

/// Stabilität der System-Regel-IDs: Voraussetzung für idempotente Upsserts.
@Suite("SystemCatalogStableIDs")
struct SystemCatalogStableIDsTests {
    @Test("IDs sind über Aufrufe stabil und kollisionsfrei")
    func idsAreStableAndUnique() {
        let first = CategoryRule.defaultCatalog()
        let second = CategoryRule.defaultCatalog()
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == first.count)
    }
}
