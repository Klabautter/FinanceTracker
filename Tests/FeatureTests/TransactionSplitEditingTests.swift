import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("TransactionSplitEditing")
struct TransactionSplitEditingTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func parent(amount: Decimal = -85) -> Transaction {
        Transaction(
            accountID: UUID(),
            source: .demo,
            externalID: "split-edit-parent",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Einkauf",
            rawMerchantName: "Einkauf",
            merchantDisplayName: "Einkauf"
        )
    }

    @Test("Edit-Format ist locale-sicher und enthält kein Währungssymbol")
    func editableAmountRoundtrip() {
        let value = Decimal(string: "1234.50")!
        let german = TransactionSplitEditorModel.editableAmountString(
            value,
            locale: Locale(identifier: "de_DE")
        )
        let english = TransactionSplitEditorModel.editableAmountString(
            value,
            locale: Locale(identifier: "en_US")
        )

        #expect(german == "1234,5")
        #expect(english == "1234.5")
        #expect(!german.contains("€"))
        #expect(TransactionSplitEditorModel.parseAmountText(german) == value)
        #expect(TransactionSplitEditorModel.parseAmountText(english) == value)
        #expect(TransactionSplitEditorModel.parseAmountText("12 €") == nil)
    }

    @Test("Ungültige Texteingabe wird nicht als 0 übernommen und löscht keinen Bestand")
    func invalidInputPreservesStoredLines() async throws {
        let dependencies = try makeDependencies()
        let transaction = parent()
        let existing = [
            TransactionSplitLine(parentTransactionID: transaction.id, amount: 60),
            TransactionSplitLine(parentTransactionID: transaction.id, amount: 25)
        ]
        try await dependencies.transactionRepository.upsert([transaction])
        try await dependencies.transactionSplitRepository.upsert(existing)

        let model = TransactionSplitEditorModel(
            parent: transaction,
            dependencies: dependencies,
            locale: Locale(identifier: "de_DE")
        )
        await model.load()
        let firstID = try #require(model.lines.first?.id)
        let originalAmount = try #require(model.lines.first?.amount)

        model.setAmountText("ungültig", for: firstID)

        #expect(model.lines.first?.amount == originalAmount)
        #expect(!model.canSave)
        #expect(await model.save() == false)
        let stored = try await dependencies.transactionSplitRepository.splitLines(
            parentTransactionID: transaction.id
        )
        #expect(Set(stored.map(\.id)) == Set(existing.map(\.id)))
    }

    @Test("Entfernte Positionen werden erst nach vollständiger Validierung ersetzt")
    func validatedReplacement() async throws {
        let dependencies = try makeDependencies()
        let transaction = parent()
        let existing = [
            TransactionSplitLine(parentTransactionID: transaction.id, amount: 60),
            TransactionSplitLine(parentTransactionID: transaction.id, amount: 25)
        ]
        try await dependencies.transactionRepository.upsert([transaction])
        try await dependencies.transactionSplitRepository.upsert(existing)

        let model = TransactionSplitEditorModel(parent: transaction, dependencies: dependencies)
        await model.load()
        model.removeLines(at: IndexSet(integer: 1))
        let remainingID = try #require(model.lines.first?.id)
        model.setAmountText("85,00", for: remainingID)

        #expect(model.canSave)
        #expect(await model.save())
        let stored = try await dependencies.transactionSplitRepository.splitLines(
            parentTransactionID: transaction.id
        )
        #expect(stored.count == 1)
        #expect(stored.first?.id == remainingID)
        #expect(stored.first?.amount == 85)
    }

    @Test("Im Split angelegte Kategorie steht sofort allen Positionen zur Wahl")
    func createdCategoryIsOffered() async throws {
        let dependencies = try makeDependencies()
        let transaction = parent()
        try await dependencies.transactionRepository.upsert([transaction])
        let model = TransactionSplitEditorModel(parent: transaction, dependencies: dependencies)
        await model.load()

        let created = Category(name: "AWS", systemIconName: "server.rack")
        model.categoryCreated(created)
        model.categoryCreated(created)

        #expect(model.leafCategories.filter { $0.id == created.id }.count == 1)
        #expect(model.leafCategories.map(\.name) == model.leafCategories.map(\.name).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        })
    }
}
