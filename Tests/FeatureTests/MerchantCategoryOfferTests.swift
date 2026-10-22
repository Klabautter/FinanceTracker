import Foundation
import Testing

@testable import FinanceTracker

/// Nach einer einzelnen Kategorie-Änderung fragt die Liste, ob die Kategorie
/// für alle Buchungen des Händlers gelten soll.
@MainActor
@Suite("MerchantCategoryOffer")
struct MerchantCategoryOfferTests {
    private typealias Catalog = FinanceTracker.Category

    private struct Fixture {
        let dependencies: AppDependencies
        let model: TransactionsModel
        let drugstore: [Transaction]
        let other: Transaction
    }

    private func transaction(_ merchant: String, amount: Decimal, account: Account, category: UUID?) -> Transaction {
        Transaction(
            accountID: account.id,
            source: .genericCSV,
            externalID: UUID().uuidString,
            kind: .purchase,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: Date(),
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant,
            categoryID: category
        )
    }

    /// Drei „Müller"-Buchungen, zwei falsch als Lebensmittel, eine offen,
    /// dazu die falsche Händler-Regel und eine fremde Buchung.
    private func makeFixture() async throws -> Fixture {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        try await dependencies.categoryRepository.upsert(Catalog.defaultCatalog())
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        let drugstore = [
            transaction("Müller", amount: -42.56, account: account, category: Catalog.groceries.id),
            transaction("Müller", amount: -17.54, account: account, category: Catalog.groceries.id),
            transaction("Müller", amount: -8, account: account, category: nil)
        ]
        let other = transaction("Radhaus Beispiel", amount: -120, account: account, category: Catalog.shopping.id)
        try await dependencies.transactionRepository.upsert(drugstore + [other])

        let wrongRule = try #require(CategoryRule.makeFromCorrection(
            transaction: drugstore[0],
            categoryID: Catalog.groceries.id,
            existingRules: []
        ))
        try await dependencies.ruleRepository.upsert([wrongRule])

        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()
        return Fixture(dependencies: dependencies, model: model, drugstore: drugstore, other: other)
    }

    private func storedCategories(_ fixture: Fixture) async throws -> [UUID: UUID?] {
        let all = try await fixture.dependencies.transactionRepository.transactions(matching: TransactionQuery())
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.categoryID) })
    }

    @Test("Einzeländerung bleibt einzeln; die Rückfrage nennt die übrigen Buchungen des Händlers")
    func offerAfterSingleChange() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let first = try #require(model.transaction(withID: fixture.drugstore[0].id))

        await model.changeCategory(first, to: Catalog.health.id)

        let offer = try #require(model.merchantCategoryOffer)
        #expect(offer.otherCount == 2)
        #expect(offer.categoryID == Catalog.health.id)
        #expect(offer.message == "Auch die 2 anderen „Müller“-Buchungen auf Gesundheit ändern und künftig so zuordnen?")

        // Bis zur Bestätigung ist nur die eine Buchung geändert.
        let stored = try await storedCategories(fixture)
        #expect(stored[fixture.drugstore[0].id] == Catalog.health.id)
        #expect(stored[fixture.drugstore[1].id] == Catalog.groceries.id)
        #expect(stored[fixture.drugstore[2].id] == .some(nil))

        model.dismissMerchantCategoryOffer()
        #expect(model.merchantCategoryOffer == nil)
        #expect(try await storedCategories(fixture)[fixture.drugstore[1].id] == Catalog.groceries.id)
    }

    @Test("„Für alle ändern“ übernimmt die Kategorie für den Händler, korrigiert die Regel und ist ein Undo-Schritt")
    func applyChangesAllAndRule() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let first = try #require(model.transaction(withID: fixture.drugstore[0].id))
        await model.changeCategory(first, to: Catalog.health.id)

        await model.applyMerchantCategoryOffer()
        #expect(model.merchantCategoryOffer == nil)

        var stored = try await storedCategories(fixture)
        for transaction in fixture.drugstore {
            #expect(stored[transaction.id] == Catalog.health.id)
            #expect(model.transaction(withID: transaction.id)?.categoryID == Catalog.health.id)
        }
        // Andere Händler bleiben unberührt.
        #expect(stored[fixture.other.id] == Catalog.shopping.id)

        let rules = try await fixture.dependencies.ruleRepository.rules().filter { $0.origin == .user }
        #expect(rules.count == 1)
        #expect(rules.first?.categoryID == Catalog.health.id)

        // ⌘Z nimmt die Händler-Übernahme zurück, die Einzeländerung bleibt.
        await model.undo()
        stored = try await storedCategories(fixture)
        #expect(stored[fixture.drugstore[0].id] == Catalog.health.id)
        #expect(stored[fixture.drugstore[1].id] == Catalog.groceries.id)
        #expect(stored[fixture.drugstore[2].id] == .some(nil))
        let restoredRules = try await fixture.dependencies.ruleRepository.rules().filter { $0.origin == .user }
        #expect(restoredRules.first?.categoryID == Catalog.groceries.id)
    }

    @Test("Ohne weitere Buchungen und ohne widersprechende Regel gibt es keine Rückfrage")
    func noOfferForSingleMerchant() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let single = try #require(model.transaction(withID: fixture.other.id))

        await model.changeCategory(single, to: Catalog.travel.id)
        #expect(model.merchantCategoryOffer == nil)

        // „Ohne Kategorie“ ist keine Zuordnung, die sich übertragen ließe.
        let first = try #require(model.transaction(withID: fixture.drugstore[0].id))
        await model.changeCategory(first, to: nil)
        #expect(model.merchantCategoryOffer == nil)
    }

    @Test("Detailansicht mit „merken“: offene Buchungen werden sofort zugeordnet, die Rückfrage nennt nur die abweichenden")
    func offerAfterRememberedChange() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let first = try #require(model.transaction(withID: fixture.drugstore[0].id))

        await model.assignCategory(first, to: Catalog.health.id, rememberMerchant: true)

        // Die bisher offene Buchung ist mitgezogen, die anders zugeordnete nicht.
        let stored = try await storedCategories(fixture)
        #expect(stored[fixture.drugstore[2].id] == Catalog.health.id)
        #expect(stored[fixture.drugstore[1].id] == Catalog.groceries.id)

        let offer = try #require(model.merchantCategoryOffer)
        #expect(offer.transactionID == first.id)
        #expect(offer.otherCount == 1)
        #expect(offer.message == "Auch die andere „Müller“-Buchung auf Gesundheit ändern und künftig so zuordnen?")

        await model.applyMerchantCategoryOffer()
        #expect(try await storedCategories(fixture)[fixture.drugstore[1].id] == Catalog.health.id)
    }

    @Test("Detailansicht ohne „merken“ fragt ebenfalls nach")
    func offerAfterPlainDetailChange() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let first = try #require(model.transaction(withID: fixture.drugstore[0].id))

        await model.assignCategory(first, to: Catalog.health.id, rememberMerchant: false)
        #expect(model.merchantCategoryOffer?.otherCount == 2)
    }
}
