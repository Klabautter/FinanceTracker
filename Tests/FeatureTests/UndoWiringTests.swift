import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("UndoWiring")
struct UndoWiringTests {
    private func makeModel() throws -> TransactionsModel {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        return TransactionsModel(dependencies: dependencies)
    }

    private func seedTransaction(in model: TransactionsModel) async throws {
        let dependencies = model.dependencies
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        try await dependencies.transactionRepository.upsert([
            Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: "undo-wiring-1",
                status: .booked,
                kind: .purchase,
                amount: Money(amount: Decimal(-10), currency: .eur),
                bookedAt: Date(),
                rawDescription: "x",
                rawMerchantName: "X",
                merchantDisplayName: "X"
            )
        ])
        await model.refresh()
    }

    @Test("Initial: kein Undo/Redo, keine Namen")
    func initialState() throws {
        let model = try makeModel()
        #expect(!model.canUndo)
        #expect(!model.canRedo)
        #expect(model.undoActionName == nil)
        #expect(model.redoActionName == nil)
    }

    @Test("Nach Edit: canUndo + Name; nach Undo: canRedo + Name")
    func namesFollowStack() async throws {
        let model = try makeModel()
        try await seedTransaction(in: model)

        await model.changeCategory(model.transactions[0], to: nil)
        #expect(model.canUndo)
        #expect(!model.canRedo)
        #expect(model.undoActionName == "Kategorie")

        await model.undo()
        #expect(!model.canUndo)
        #expect(model.canRedo)
        #expect(model.redoActionName == "Kategorie")

        await model.redo()
        #expect(model.canUndo)
        #expect(!model.canRedo)
    }

    @Test("Neuer Edit leert Redo")
    func newEditClearsRedo() async throws {
        let model = try makeModel()
        try await seedTransaction(in: model)

        await model.changeCategory(model.transactions[0], to: nil)
        await model.undo()
        #expect(model.canRedo)

        await model.toggleReviewed(model.transactions[0], reviewed: true)
        #expect(model.canUndo)
        #expect(!model.canRedo)
        #expect(model.undoActionName == "Prüfstatus")
    }
}
