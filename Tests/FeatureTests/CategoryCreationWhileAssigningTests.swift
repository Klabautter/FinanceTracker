import Foundation
import Testing

@testable import FinanceTracker

/// Neue Kategorie direkt aus einer Kategorieauswahl anlegen und zuordnen.
@MainActor
@Suite("CategoryCreationWhileAssigning")
struct CategoryCreationWhileAssigningTests {
    private typealias Catalog = FinanceTracker.Category

    private func setup(merchants: [String]) async throws -> (AppDependencies, [Transaction]) {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        try await dependencies.categoryRepository.upsert(Catalog.defaultCatalog())
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let transactions = merchants.map { merchant in
            Transaction(
                accountID: account.id,
                source: .genericCSV,
                externalID: UUID().uuidString,
                kind: .purchase,
                amount: Money(amount: -20, currency: .eur),
                bookedAt: Date(),
                rawDescription: merchant,
                rawMerchantName: merchant,
                merchantDisplayName: merchant
            )
        }
        try await dependencies.transactionRepository.upsert(transactions)
        return (dependencies, transactions)
    }

    private func storedCategory(_ id: UUID, _ dependencies: AppDependencies) async throws -> UUID? {
        try await dependencies.transactionRepository.transaction(id: id)?.categoryID
    }

    @Test("Transaktionsliste: neue Kategorie wird angelegt und der Buchung zugeordnet, danach die Händler-Rückfrage")
    func createAndAssignInList() async throws {
        let (dependencies, transactions) = try await setup(merchants: ["Techniker Krankenkasse", "Techniker Krankenkasse"])
        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()
        let insurance = Catalog(name: "Versicherungen", systemIconName: "shield", colorToken: .teal)
        try await dependencies.categoryRepository.upsert([insurance])

        let first = try #require(model.transaction(withID: transactions[0].id))
        await model.categoryCreated(insurance, for: .transaction(first))

        #expect(model.categoriesByID[insurance.id] != nil)
        #expect(try await storedCategory(transactions[0].id, dependencies) == insurance.id)
        #expect(model.merchantCategoryOffer?.otherCount == 1)
    }

    @Test("Mehrfachauswahl: neue Kategorie gilt für alle ausgewählten Buchungen")
    func createAndAssignSelection() async throws {
        let (dependencies, transactions) = try await setup(merchants: ["A Laden", "B Laden"])
        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()
        let hobby = Catalog(name: "Hobby", systemIconName: "paintbrush", colorToken: .purple)
        try await dependencies.categoryRepository.upsert([hobby])

        await model.categoryCreated(hobby, for: .selection(Set(transactions.map(\.id))))

        for transaction in transactions {
            #expect(try await storedCategory(transaction.id, dependencies) == hobby.id)
        }
    }

    @Test("Prüfliste: neue Kategorie wird dem Händler zugeordnet")
    func createAndAssignInReviewQueue() async throws {
        let (dependencies, transactions) = try await setup(merchants: ["Techniker Krankenkasse", "Techniker Krankenkasse"])
        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()
        let entry = try #require(model.entries(for: .categorize).first)
        let insurance = Catalog(name: "Versicherungen", systemIconName: "shield", colorToken: .teal)
        try await dependencies.categoryRepository.upsert([insurance])

        model.requestCategoryCreation(for: entry)
        let request = try #require(model.categoryCreationRequest)
        await model.categoryCreated(insurance, for: request)

        for transaction in transactions {
            #expect(try await storedCategory(transaction.id, dependencies) == insurance.id)
        }
    }

    @Test("Namensvergleich für Dubletten ignoriert Groß-/Kleinschreibung und Umlaut-Punkte")
    func duplicateNameKey() {
        #expect(CategoryEditorSheet.comparisonKey(" Versicherungen ") == CategoryEditorSheet.comparisonKey("versicherungen"))
        #expect(CategoryEditorSheet.comparisonKey("Gebühren") == CategoryEditorSheet.comparisonKey("GEBUHREN"))
    }
}
