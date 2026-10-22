import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("UndoRedo")
struct UndoRedoTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    @Test("Kategorie-Änderung ist per Undo rückholbar")
    func undoCategoryChange() async throws {
        let dependencies = try makeDependencies()
        let model = TransactionsModel(dependencies: dependencies)

        let category = Category(name: "Testkat", systemIconName: "tag")
        try await dependencies.categoryRepository.upsert([category])
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let txn = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .demo,
            externalID: "undo-1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(10), currency: .eur),
            bookedAt: Date(),
            rawDescription: "x",
            rawMerchantName: "X",
            merchantDisplayName: "X",
            categoryID: category.id
        )
        try await dependencies.transactionRepository.upsert([txn])
        await model.refresh()

        // Ändern
        await model.changeCategory(model.transactions[0], to: nil)
        #expect(model.errorMessage == nil)
        #expect(model.transactions[0].categoryID == nil, "direkt nach changeCategory")

        // Undo (deterministischer eigener Stack)
        await model.undo()
        #expect(model.transactions[0].categoryID == category.id)

        // Redo
        await model.redo()
        #expect(model.transactions[0].categoryID == nil)
    }

    @Test("Reviewed-Änderung ist per Undo rückholbar")
    func undoReviewedToggle() async throws {
        let dependencies = try makeDependencies()
        let model = TransactionsModel(dependencies: dependencies)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let txn = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .demo,
            externalID: "undo-2",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(10), currency: .eur),
            bookedAt: Date(),
            rawDescription: "x",
            rawMerchantName: "X",
            merchantDisplayName: "X"
        )
        try await dependencies.transactionRepository.upsert([txn])
        await model.refresh()

        await model.toggleReviewed(model.transactions[0], reviewed: true)
        #expect(model.transactions[0].reviewed)

        await model.undo()
        #expect(!model.transactions[0].reviewed)
    }
}
