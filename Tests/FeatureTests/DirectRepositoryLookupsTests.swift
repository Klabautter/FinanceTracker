import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

/// WP20: Store-seitige Direct-ID-Lookups + Category-Usage-Counts.
@MainActor
@Suite("DirectRepositoryLookups")
struct DirectRepositoryLookupsTests {

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    @Test("account(id:)/category(id:)/budget(id:) liefern gezielt und nil bei Unbekannt")
    func directLookups() async throws {
        let dependencies = try makeDependencies()

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let category = Category(name: "Lebensmittel", systemIconName: "cart")
        try await dependencies.categoryRepository.upsert([category])

        let budget = Budget(name: "Wocheneinkauf", amount: 250, categoryIDs: [category.id])
        try await dependencies.budgetRepository.upsert([budget])

        // Direkt-Lookups treffen genau die Entity.
        #expect(try await dependencies.accountRepository.account(id: account.id)?.name == "Giro")
        #expect(try await dependencies.categoryRepository.category(id: category.id)?.name == "Lebensmittel")
        #expect(try await dependencies.budgetRepository.budget(id: budget.id)?.amount == 250)

        // Unbekannte IDs → nil (kein Crash, kein Full-Scan-Verhalten sichtbar).
        #expect(try await dependencies.accountRepository.account(id: UUID()) == nil)
        #expect(try await dependencies.categoryRepository.category(id: UUID()) == nil)
        #expect(try await dependencies.budgetRepository.budget(id: UUID()) == nil)
    }

    @Test("Category-Usage-Counts zählen Zuordnungen ohne Full-Domain-Load")
    func categoryUsageCounts() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let food = Category(name: "Lebensmittel", systemIconName: "cart")
        let rent = Category(name: "Miete", systemIconName: "house")
        try await dependencies.categoryRepository.upsert([food, rent])

        func expense(_ categoryID: UUID?) -> Transaction {
            Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: UUID().uuidString,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -Decimal(10), currency: .eur),
                bookedAt: Date(),
                rawDescription: "Händler",
                rawMerchantName: "Händler",
                merchantDisplayName: "Händler",
                categoryID: categoryID
            )
        }

        try await dependencies.transactionRepository.upsert([
            expense(food.id),
            expense(food.id),
            expense(food.id),
            expense(rent.id),
            expense(nil)
        ])

        let counts = try await dependencies.categoryRepository.usageCounts()
        #expect(counts[food.id] == 3)
        #expect(counts[rent.id] == 1)
        #expect(counts.count == 2) // ohne Kategorie nicht gezählt
    }
}
