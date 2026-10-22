import Foundation
import Testing

@testable import FinanceTracker

@Suite("GroupExpense")
struct GroupExpenseTests {
    private func share(
        paidBy: String = "Alex",
        owedBy: String = "Mara",
        amount: Decimal = 30,
        currency: CurrencyCode = .eur,
        settled: Bool = false
    ) throws -> SharedExpenseShare {
        try SharedExpenseShare(
            transactionID: UUID(),
            paidBy: paidBy,
            owedBy: owedBy,
            shareAmount: amount,
            shareCurrency: currency,
            settled: settled
        )
    }

    @Test("Validierung: leere Teilnehmer und Null-Anteile abgelehnt")
    func validation() {
        #expect(throws: GroupExpenseValidationError.self) {
            _ = try SharedExpenseShare(
                transactionID: UUID(), paidBy: " ", owedBy: "Mara",
                shareAmount: 10, shareCurrency: .eur
            )
        }
        #expect(throws: GroupExpenseValidationError.self) {
            _ = try SharedExpenseShare(
                transactionID: UUID(), paidBy: "Alex", owedBy: "Alex",
                shareAmount: 10, shareCurrency: .eur
            )
        }
        #expect(throws: GroupExpenseValidationError.self) {
            _ = try SharedExpenseShare(
                transactionID: UUID(), paidBy: "Alex", owedBy: "Mara",
                shareAmount: 0, shareCurrency: .eur
            )
        }
    }

    @Test("Salden: Zahler im Plus, Schuldner im Minus (je Währung)")
    func balances() throws {
        let resolver = GroupExpenseResolver()
        let balances = resolver.netBalances(shares: [
            try share(paidBy: "Alex", owedBy: "Mara", amount: 30),
            try share(paidBy: "Alex", owedBy: "Jon", amount: 20)
        ])
        #expect(balances[.eur]?["Alex"] == 50)
        #expect(balances[.eur]?["Mara"] == -30)
        #expect(balances[.eur]?["Jon"] == -20)
    }

    @Test("Währungen werden nie vermischt (#19/#35)")
    func currenciesKeptSeparate() throws {
        let resolver = GroupExpenseResolver()
        let balances = resolver.netBalances(shares: [
            try share(paidBy: "Alex", owedBy: "Mara", amount: 30, currency: .eur),
            try share(paidBy: "Alex", owedBy: "Mara", amount: 30, currency: .usd)
        ])
        #expect(balances[.eur]?["Alex"] == 30)
        #expect(balances[.usd]?["Alex"] == 30)
        #expect(balances.count == 2)

        let transfers = resolver.settlementTransfers(shares: [
            try share(paidBy: "Alex", owedBy: "Mara", amount: 30, currency: .eur),
            try share(paidBy: "Alex", owedBy: "Mara", amount: 30, currency: .usd)
        ])
        #expect(transfers.count == 2)
        #expect(Set(transfers.map(\.currency)) == [.eur, .usd])
    }

    @Test("Erledigte Anteile zählen nicht")
    func settledExcluded() throws {
        let resolver = GroupExpenseResolver()
        let balances = resolver.netBalances(shares: [
            try share(amount: 30, settled: true),
            try share(paidBy: "Alex", owedBy: "Jon", amount: 20)
        ])
        #expect(balances[.eur]?["Alex"] == 20)
        #expect(balances[.eur]?["Mara"] == nil)
    }

    @Test("Ausgleich ist neutral (Transfer, kein PIS)")
    func settlementIsNeutralTransfer() throws {
        let resolver = GroupExpenseResolver()
        let transfers = resolver.settlementTransfers(shares: [
            try share(paidBy: "Alex", owedBy: "Mara", amount: 30),
            try share(paidBy: "Alex", owedBy: "Jon", amount: 20)
        ])
        #expect(transfers.count == 2)
        // Deterministisch: größter Schuldner zuerst (Mara 30, Jon 20).
        #expect(transfers[0].from == "Mara")
        #expect(transfers[0].amount == 30)

        let txn = resolver.settlementTransaction(for: transfers[0], accountID: UUID())
        #expect(txn.kind == .transfer)
        #expect(txn.source == .manual)
        if case .neutral = CashflowPolicy.shared.contribution(for: txn) {
        } else {
            Issue.record("Ausgleichs-Transfer muss neutral sein (#28)")
        }
    }
}
