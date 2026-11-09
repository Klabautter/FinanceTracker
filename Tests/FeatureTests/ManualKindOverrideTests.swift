import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("ManualKindOverride")
struct ManualKindOverrideTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    @Test("setManualKind persistiert Override, Resolver übernimmt ihn, Reset entfernt ihn")
    func overrideLifecycle() async throws {
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
            externalID: "override-1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(string: "300.00")!, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Überweisung",
            rawMerchantName: "Bank",
            merchantDisplayName: "Bank"
        )
        try await dependencies.transactionRepository.upsert([txn])
        await model.refresh()

        // Override: Transfer (User gewinnt über Detector: Roadmap #64)
        await model.setManualKind(.transfer, on: model.transactions[0])
        #expect(model.transactions[0].kind == .transfer)
        #expect(model.manualKindOverrides[txn.id] == .transfer)

        // Persistiert in der Annotation
        let annotation = try #require(
            await dependencies.transactionAnnotationRepository.annotation(transactionID: txn.id)
        )
        #expect(annotation.manualKindOverride == .transfer)

        // Reset: Override entfernen
        await model.setManualKind(nil, on: model.transactions[0])
        #expect(model.transactions[0].kind == .purchase)
        #expect(model.manualKindOverrides[txn.id] == nil)

        let annotationAfterReset = try #require(
            await dependencies.transactionAnnotationRepository.annotation(transactionID: txn.id)
        )
        #expect(annotationAfterReset.manualKindOverride == nil)
    }

    /// Legt ein Konto, eine Kategorie und eine Kartenzahlung an und lädt die Liste.
    private func makeLoadedModel() async throws -> (
        model: TransactionsModel, dependencies: AppDependencies, transactionID: UUID, categoryID: UUID
    ) {
        let dependencies = try makeDependencies()
        let model = TransactionsModel(dependencies: dependencies)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        let category = Category(name: "Umbuchung privat", systemIconName: "arrow.left.arrow.right")
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.categoryRepository.upsert([category])
        let txn = Transaction(
            accountID: account.id,
            source: .demo,
            externalID: "override-raw",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -300, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Überweisung",
            rawMerchantName: "Bank",
            merchantDisplayName: "Bank"
        )
        try await dependencies.transactionRepository.upsert([txn])
        await model.refresh()
        return (model, dependencies, txn.id, category.id)
    }

    private func storedKind(_ id: UUID, _ dependencies: AppDependencies) async throws -> TransactionKind? {
        try await dependencies.transactionRepository.transaction(id: id)?.kind
    }

    @Test("Kategorie ändern schreibt den manuellen Typ nicht in die gespeicherte Buchung")
    func changeCategoryKeepsStoredKind() async throws {
        let (model, dependencies, id, categoryID) = try await makeLoadedModel()

        await model.setManualKind(.transfer, on: model.transactions[0])
        await model.changeCategory(model.transactions[0], to: categoryID, offersMerchantChange: false)

        // Liste zeigt weiter den manuellen Typ, die Buchung behält ihren eigenen.
        #expect(model.transactions[0].kind == .transfer)
        #expect(model.transactions[0].categoryID == categoryID)
        #expect(try await storedKind(id, dependencies) == .purchase)
        #expect(try await dependencies.transactionRepository.transaction(id: id)?.categoryID == categoryID)

        // Zurücksetzen des Typs stellt den ursprünglichen wieder her.
        await model.setManualKind(nil, on: model.transactions[0])
        #expect(model.transactions[0].kind == .purchase)
        #expect(model.transactions[0].categoryID == categoryID)
    }

    @Test("Kategorie rückgängig/wiederholen lässt den gespeicherten Typ unberührt")
    func changeCategoryUndoRedoKeepsStoredKind() async throws {
        let (model, dependencies, id, categoryID) = try await makeLoadedModel()

        await model.setManualKind(.transfer, on: model.transactions[0])
        await model.changeCategory(model.transactions[0], to: categoryID, offersMerchantChange: false)

        await model.undo()
        #expect(model.transactions[0].categoryID == nil)
        #expect(model.transactions[0].kind == .transfer)
        #expect(try await storedKind(id, dependencies) == .purchase)
        #expect(try await dependencies.transactionRepository.transaction(id: id)?.categoryID == nil)

        await model.redo()
        #expect(model.transactions[0].categoryID == categoryID)
        #expect(model.transactions[0].kind == .transfer)
        #expect(try await storedKind(id, dependencies) == .purchase)
        #expect(try await dependencies.transactionRepository.transaction(id: id)?.categoryID == categoryID)
    }

    @Test("Sammel-Kategorie schreibt den manuellen Typ nicht in die gespeicherte Buchung")
    func bulkChangeCategoryKeepsStoredKind() async throws {
        let (model, dependencies, id, categoryID) = try await makeLoadedModel()

        await model.setManualKind(.transfer, on: model.transactions[0])
        await model.bulkChangeCategory(categoryID, for: [id])
        #expect(model.transactions[0].kind == .transfer)
        #expect(try await storedKind(id, dependencies) == .purchase)
        #expect(try await dependencies.transactionRepository.transaction(id: id)?.categoryID == categoryID)

        await model.undo()
        #expect(model.transactions[0].categoryID == nil)
        #expect(try await storedKind(id, dependencies) == .purchase)
        #expect(try await dependencies.transactionRepository.transaction(id: id)?.categoryID == nil)

        await model.redo()
        #expect(model.transactions[0].categoryID == categoryID)
        #expect(try await storedKind(id, dependencies) == .purchase)
    }

    @Test("Notiz rückgängig machen schreibt den manuellen Typ nicht in die gespeicherte Buchung")
    func annotationUndoKeepsStoredKind() async throws {
        let (model, dependencies, id, _) = try await makeLoadedModel()

        await model.setManualKind(.transfer, on: model.transactions[0])
        await model.updateNote(model.transactions[0], note: "Urlaubskasse")
        await model.undo()

        #expect(model.transactions[0].note == nil)
        #expect(model.transactions[0].kind == .transfer)
        #expect(try await storedKind(id, dependencies) == .purchase)
        // Die Notiz gehört in die Annotation, nicht in die Buchung.
        #expect(try await dependencies.transactionRepository.transaction(id: id)?.note == nil)

        await model.redo()
        #expect(model.transactions[0].note == "Urlaubskasse")
        #expect(try await storedKind(id, dependencies) == .purchase)
        #expect(try await dependencies.transactionRepository.transaction(id: id)?.note == nil)
    }
}
