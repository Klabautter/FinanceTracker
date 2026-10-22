import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@Suite("Manuelle Buchungen bearbeiten und löschen")
@MainActor
struct ManualTransactionEditingTests {
    private func makeDependencies() throws -> (AppDependencies, SwiftDataStore) {
        let store = try SwiftDataStore(inMemory: true)
        return (AppDependencies.make(container: store.container, baseCurrency: .eur), store)
    }

    private func addExpense(_ dependencies: AppDependencies, account: Account, amount: String, merchant: String) async throws -> Transaction {
        let model = AddTransactionModel(dependencies: dependencies)
        await model.load()
        model.draft.amountText = amount
        model.draft.merchant = merchant
        model.draft.accountID = account.id
        #expect(await model.save())
        let all = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        return try #require(all.first { $0.effectiveMerchantName == merchant })
    }

    @Test("Bearbeiten ändert Betrag, Händler und Art, behält ID und Prüfstatus")
    func editKeepsIdentityAndAnnotation() async throws {
        let (dependencies, _) = try makeDependencies()
        let account = Account(name: "Geldbeutel", type: .cash, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let original = try await addExpense(dependencies, account: account, amount: "12,34", merchant: "Tippfehler")
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(transactionID: original.id, reviewed: true)
        ])

        let editor = AddTransactionModel(dependencies: dependencies, editing: original)
        await editor.load()
        #expect(editor.draft.amountText == "12,34")
        #expect(editor.draft.kind == .expense)
        editor.draft.amountText = "21,50"
        editor.draft.merchant = "Bäckerei"
        editor.draft.kind = .income
        editor.draft.note = "korrigiert"
        #expect(await editor.save())

        let all = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(all.count == 1)
        let updated = try #require(all.first)
        #expect(updated.id == original.id)
        #expect(updated.externalID == original.externalID)
        #expect(updated.amount.amount == Decimal(string: "21.50"))
        #expect(updated.kind == .income)
        #expect(updated.effectiveMerchantName == "Bäckerei")
        let annotation = try #require(try await dependencies.transactionAnnotationRepository.annotation(transactionID: original.id))
        #expect(annotation.reviewed)
        #expect(annotation.note == "korrigiert")
    }

    @Test("Löschen entfernt nur die gewählte manuelle Buchung und ist rückholbar")
    func deleteAndUndo() async throws {
        let (dependencies, store) = try makeDependencies()
        let account = Account(name: "Geldbeutel", type: .cash, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let doomed = try await addExpense(dependencies, account: account, amount: "5", merchant: "Weg damit")
        let kept = try await addExpense(dependencies, account: account, amount: "7", merchant: "Bleibt")

        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()
        await model.deleteManualTransaction(doomed)

        #expect(model.transactions.map(\.id) == [kept.id])
        #expect(try await dependencies.transactionRepository.count() == 1)
        let context = ModelContext(store.container)
        #expect(try context.fetch(FetchDescriptor<SDTransactionSearchEntity>()).allSatisfy { $0.transactionID == kept.id })

        await model.undo()
        #expect(try await dependencies.transactionRepository.count() == 2)
        #expect(Set(model.transactions.map(\.id)) == [doomed.id, kept.id])

        await model.redo()
        #expect(try await dependencies.transactionRepository.count() == 1)
    }

    @Test("Bank-Buchungen sind weder lösch- noch bearbeitbar")
    func providerTransactionsAreProtected() async throws {
        let (dependencies, _) = try makeDependencies()
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([account])
        let bank = Transaction(
            accountID: account.id, source: .openBanking, status: .booked, kind: .purchase,
            amount: Money(amount: -10, currency: .eur), bookedAt: Date(),
            rawDescription: "BILLA", rawMerchantName: "BILLA", merchantDisplayName: "BILLA"
        )
        try await dependencies.transactionRepository.upsert([bank])

        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()
        #expect(!model.canDeleteManually(bank))
        #expect(!model.canEditManually(bank))
        await model.deleteManualTransaction(bank)
        #expect(try await dependencies.transactionRepository.count() == 1)
    }

    @Test("Ein manueller Transfer wird mit seiner Gegenbuchung gelöscht")
    func deletingTransferRemovesBothLegs() async throws {
        let (dependencies, _) = try makeDependencies()
        let giro = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        let cash = Account(name: "Geldbeutel", type: .cash, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([giro, cash])
        let other = try await addExpense(dependencies, account: cash, amount: "3", merchant: "Bleibt")

        let adder = AddTransactionModel(dependencies: dependencies)
        await adder.load()
        adder.draft.kind = .transfer
        adder.draft.amountText = "50"
        adder.transferDraft.fromAccountID = giro.id
        adder.transferDraft.toAccountID = cash.id
        #expect(await adder.save())
        #expect(try await dependencies.transactionRepository.count() == 3)

        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()
        let leg = try #require(model.transactions.first { $0.kind == .transfer })
        #expect(model.isTransferPairLeg(leg))
        #expect(!model.canEditManually(leg))
        await model.deleteManualTransaction(leg)

        let remaining = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(remaining.map(\.id) == [other.id])
    }
}
