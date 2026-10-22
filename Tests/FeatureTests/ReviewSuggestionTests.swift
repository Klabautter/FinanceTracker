import Foundation
import Testing

@testable import FinanceTracker

/// Verlauf-Vorschläge in der Prüfliste: Offene „REWE“-Buchungen bekommen
/// „Lebensmittel“ per 1 Klick (plus Händler-Regel), Bulk räumt alles ab.
@MainActor
@Suite("ReviewSuggestions")
struct ReviewSuggestionTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func seed() async throws -> (AppDependencies, FinanceTracker.Category) {
        let dependencies = try makeDependencies()
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let food = Category(name: "Lebensmittel", systemIconName: "cart")
        try await dependencies.categoryRepository.upsert([food])

        func txn(merchant: String, categoryID: UUID?) -> Transaction {
            Transaction(
                accountID: account.id,
                source: .manual,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -12, currency: .eur),
                bookedAt: Date(),
                rawDescription: merchant,
                rawMerchantName: merchant,
                merchantDisplayName: merchant,
                categoryID: categoryID
            )
        }

        try await dependencies.transactionRepository.upsert([
            txn(merchant: "REWE 111", categoryID: food.id),
            txn(merchant: "REWE 222", categoryID: food.id),
            txn(merchant: "REWE 333", categoryID: food.id),
            txn(merchant: "REWE 444", categoryID: nil),
            txn(merchant: "REWE 555", categoryID: nil),
        ])
        return (dependencies, food)
    }

    @Test("Offene Händler-Buchungen bekommen einen Vorschlag")
    func suggestionsAppear() async throws {
        let (dependencies, food) = try await seed()
        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()

        #expect(model.entries(for: .categorize).count == 2)
        #expect(model.suggestions.count == 2)
        for entry in model.entries(for: .categorize) {
            let suggestion = try #require(model.suggestionCategory(for: entry))
            #expect(suggestion.0.id == food.id)
            #expect(suggestion.1 == 3)
        }
        #expect(model.suggestedCategorizeEntries.count == 2)
    }

    @Test("Alle Vorschläge übernehmen räumt ab und merkt die Regel")
    func acceptAllClearsAndRemembers() async throws {
        let (dependencies, food) = try await seed()
        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()
        #expect(model.suggestedCategorizeEntries.count == 2)

        await model.acceptAllSuggestions()

        #expect(model.entries(for: .categorize).isEmpty)
        let rules = try await dependencies.ruleRepository.rules()
        #expect(rules.contains { $0.origin == .user && $0.categoryID == food.id })

        var query = TransactionQuery()
        query.searchText = "REWE"
        let stored = try await dependencies.transactionRepository.transactions(matching: query)
        #expect(stored.count == 5)
        #expect(stored.allSatisfy { $0.categoryID == food.id })
    }

    @Test("Ohne Verlauf kein Vorschlag, Menü bleibt")
    func noHistoryNoSuggestion() async throws {
        let dependencies = try makeDependencies()
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.categoryRepository.upsert([
            Category(name: "Lebensmittel", systemIconName: "cart")
        ])
        try await dependencies.transactionRepository.upsert([
            Transaction(
                accountID: account.id,
                source: .manual,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -12, currency: .eur),
                bookedAt: Date(),
                rawDescription: "Unbekannter Laden 7",
                rawMerchantName: "Unbekannter Laden 7",
                merchantDisplayName: "Unbekannter Laden 7"
            )
        ])

        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()
        #expect(model.entries(for: .categorize).count == 1)
        #expect(model.suggestions.isEmpty)
        #expect(model.suggestedCategorizeEntries.isEmpty)
    }
}
