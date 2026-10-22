import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("GroupExpenseSectionModel")
struct GroupExpenseSectionModelTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func sampleTransaction(accountID: UUID = UUID()) -> Transaction {
        Transaction(
            accountID: accountID,
            source: .manual,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -90, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Abendessen",
            merchantDisplayName: "Ristorante"
        )
    }

    @Test("Validierung: leere Namen, gleiche Personen und Null-Betrag abgelehnt")
    func addValidation() async throws {
        let dependencies = try makeDependencies()
        let txn = sampleTransaction()
        try await dependencies.transactionRepository.upsert([txn])
        let model = GroupExpenseSectionModel(transaction: txn, dependencies: dependencies)
        await model.load()

        #expect(await model.addShare(paidBy: " ", owedBy: "Mara", amountText: "10", currency: .eur) == false)
        #expect(model.errorMessage != nil)
        #expect(model.shares.isEmpty)

        let samePerson = await model.addShare(paidBy: "Alex", owedBy: "Alex", amountText: "10", currency: .eur)
        #expect(samePerson == false)
        #expect(model.shares.isEmpty)

        let zeroAmount = await model.addShare(paidBy: "Alex", owedBy: "Mara", amountText: "0", currency: .eur)
        #expect(zeroAmount == false)
        #expect(model.shares.isEmpty)

        let badAmount = await model.addShare(paidBy: "Alex", owedBy: "Mara", amountText: "kein-betrag", currency: .eur)
        #expect(badAmount == false)
        #expect(model.shares.isEmpty)
    }

    @Test("Hinzufügen + Salden je Währung getrennt (#19/#35)")
    func addAndSeparateCurrencies() async throws {
        let dependencies = try makeDependencies()
        let txn = sampleTransaction()
        try await dependencies.transactionRepository.upsert([txn])
        let model = GroupExpenseSectionModel(transaction: txn, dependencies: dependencies)
        await model.load()

        let addedEUR = await model.addShare(paidBy: "Alex", owedBy: "Mara", amountText: "30", currency: .eur)
        #expect(addedEUR == true)
        let addedUSD = await model.addShare(paidBy: "Alex", owedBy: "Mara", amountText: "30", currency: .usd)
        #expect(addedUSD == true)
        #expect(model.shares.count == 2)
        #expect(model.balances.count == 2)
        #expect(model.balances[.eur]?["Alex"] == 30)
        #expect(model.balances[.usd]?["Alex"] == 30)

        #expect(model.transfers.count == 2)
        #expect(Set(model.transfers.map(\.currency)) == [.eur, .usd])
    }

    @Test("Erledigte Anteile zählen nicht (settled-Ausschluss)")
    func settledExcludedFromBalances() async throws {
        let dependencies = try makeDependencies()
        let txn = sampleTransaction()
        try await dependencies.transactionRepository.upsert([txn])
        let model = GroupExpenseSectionModel(transaction: txn, dependencies: dependencies)
        await model.load()

        let firstAdded = await model.addShare(paidBy: "Alex", owedBy: "Mara", amountText: "30", currency: .eur)
        #expect(firstAdded == true)
        let secondAdded = await model.addShare(paidBy: "Alex", owedBy: "Jon", amountText: "20", currency: .eur)
        #expect(secondAdded == true)
        #expect(model.transfers.count == 2)

        let maraShare = try #require(model.shares.first { $0.owedBy == "Mara" })
        await model.setSettled(id: maraShare.id, settled: true)

        #expect(model.balances[.eur]?["Mara"] == nil)
        #expect(model.balances[.eur]?["Alex"] == 20)
        #expect(model.transfers.count == 1)
        #expect(model.transfers.first?.from == "Jon")
    }

    @Test("Ausgleich bucht neutralen manuellen Transfer, ohne Auto-Settle (#28/#15)")
    func bookSettlementIsNeutralManualTransfer() async throws {
        let dependencies = try makeDependencies()
        let accountID = UUID()
        let txn = sampleTransaction(accountID: accountID)
        try await dependencies.transactionRepository.upsert([txn])
        let model = GroupExpenseSectionModel(transaction: txn, dependencies: dependencies)
        await model.load()

        let shareAdded = await model.addShare(paidBy: "Alex", owedBy: "Mara", amountText: "30", currency: .eur)
        #expect(shareAdded == true)
        let transfer = try #require(model.transfers.first)

        // Fabrik: Transfer-Buchung auf dem Transaktionskonto.
        let booking = model.settlementTransaction(for: transfer)
        #expect(booking.kind == .transfer)
        #expect(booking.source == .manual)
        #expect(booking.accountID == accountID)
        if case .neutral = CashflowPolicy.shared.contribution(for: booking) {
        } else {
            Issue.record("Ausgleichs-Transfer muss Cashflow-neutral sein (#28)")
        }

        // Persistenter Buchungspfad: neue Transaktion, Anteile bleiben offen.
        let booked = await model.bookSettlement(transfer)
        #expect(booked == true)
        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.contains { $0.kind == .transfer && $0.source == .manual })
        #expect(model.openShareCount == 1)
    }

    @Test("Löschen entfernt Anteil persistiert")
    func deletePersists() async throws {
        let dependencies = try makeDependencies()
        let txn = sampleTransaction()
        try await dependencies.transactionRepository.upsert([txn])
        let model = GroupExpenseSectionModel(transaction: txn, dependencies: dependencies)
        await model.load()

        let added = await model.addShare(paidBy: "Alex", owedBy: "Mara", amountText: "30", currency: .eur)
        #expect(added == true)
        let id = try #require(model.shares.first?.id)
        await model.deleteShare(id: id)
        #expect(model.shares.isEmpty)
        #expect(try await dependencies.sharedExpenseShareRepository.shares(transactionID: txn.id).isEmpty)
    }

    @Test("Ausgleich-Zielkonto wählbar, Default Transaktionskonto (#15)")
    func settlementTargetAccountSelectable() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo),
            Account(name: "Bar", type: .cash, currency: .eur, source: .manual),
        ])
        let accounts = try await dependencies.accountRepository.accounts()
        let giro = try #require(accounts.first { $0.name == "Giro" })
        let bar = try #require(accounts.first { $0.name == "Bar" })

        let txn = sampleTransaction(accountID: giro.id)
        try await dependencies.transactionRepository.upsert([txn])
        let model = GroupExpenseSectionModel(transaction: txn, dependencies: dependencies)
        await model.load()
        #expect(model.availableAccounts.count == 2)

        let added = await model.addShare(paidBy: "Alex", owedBy: "Mara", amountText: "30", currency: .eur)
        #expect(added == true)
        let transfer = try #require(model.transfers.first)

        // Default: Transaktionskonto.
        #expect(model.settlementTransaction(for: transfer).accountID == giro.id)

        // Explizit gewählt: Zielkonto.
        model.settlementAccountID = bar.id
        #expect(model.settlementTransaction(for: transfer).accountID == bar.id)

        // Persistenter Pfad bucht auf dem Zielkonto, manuell, neutral.
        let booked = await model.bookSettlement(transfer)
        #expect(booked == true)
        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let settlement = try #require(stored.first { $0.kind == .transfer && $0.source == .manual })
        #expect(settlement.accountID == bar.id)
        if case .neutral = CashflowPolicy.shared.contribution(for: settlement) {
        } else {
            Issue.record("Ausgleichs-Transfer muss Cashflow-neutral sein (#28)")
        }
        // Anteile bleiben offen, kein Auto-Settle.
        #expect(model.openShareCount == 1)
    }
}
