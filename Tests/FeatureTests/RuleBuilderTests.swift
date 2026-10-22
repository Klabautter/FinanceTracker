import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("RuleBuilder")
struct RuleBuilderTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    @Test("Regel speichern mit origin user und Priorität über Bestand")
    func saveUserRule() async throws {
        let dependencies = try makeDependencies()

        let catalog = Category.defaultCatalog()
        try await dependencies.categoryRepository.upsert(catalog)
        let target = try #require(catalog.first(where: { $0.parentID != nil }))

        try await dependencies.ruleRepository.upsert([
            CategoryRule(priority: 100, condition: .merchantContains("EXISTIEREND"), categoryID: target.id, origin: .system)
        ])

        let newRule = CategoryRule(
            priority: 110,
            condition: .merchantContains("REWE"),
            categoryID: target.id,
            origin: .user
        )
        try await dependencies.ruleRepository.upsert([newRule])

        let rules = try await dependencies.ruleRepository.rules()
        #expect(rules.count == 2)

        // User-Regeln gewinnen über System-Regeln (#57/#58)
        let engine = CategoryRuleEngine()
        let txn = Transaction(
            accountID: UUID(),
            source: .demo,
            externalID: "x",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(10), currency: .eur),
            bookedAt: Date(),
            rawDescription: "REWE 123",
            rawMerchantName: "REWE MARKT",
            merchantDisplayName: "REWE"
        )
        let matched = engine.firstMatch(in: rules, for: txn)
        #expect(matched?.origin == .user)
        #expect(matched?.categoryID == target.id)
    }

    @Test("Preview-Pushdown: merchantContains findet Treffer über searchText")
    func previewPushdown() async throws {
        let dependencies = try makeDependencies()

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let calendar = Calendar(identifier: .gregorian)
        let rows = [
            Transaction(
                id: UUID(), accountID: account.id, source: .demo, externalID: "a",
                status: .booked, kind: .purchase,
                amount: Money(amount: -Decimal(10), currency: .eur),
                bookedAt: calendar.date(byAdding: .day, value: -1, to: Date()),
                rawDescription: "REWE 111",
                rawMerchantName: "REWE", merchantDisplayName: "REWE"
            ),
            Transaction(
                id: UUID(), accountID: account.id, source: .demo, externalID: "b",
                status: .booked, kind: .purchase,
                amount: Money(amount: -Decimal(12), currency: .eur),
                bookedAt: calendar.date(byAdding: .day, value: -2, to: Date()),
                rawDescription: "SHELL 222",
                rawMerchantName: "SHELL", merchantDisplayName: "SHELL"
            )
        ]
        try await dependencies.transactionRepository.upsert(rows)

        var query = TransactionQuery()
        query.searchText = "rewe"
        let candidates = try await dependencies.transactionRepository.transactions(matching: query)

        #expect(candidates.count == 1)
        #expect(candidates.first?.merchantDisplayName == "REWE")
    }
}
