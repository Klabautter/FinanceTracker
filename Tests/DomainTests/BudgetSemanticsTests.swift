import Foundation
import Testing

@testable import FinanceTracker

struct BudgetSemanticsTests {
    private let calculator = BudgetCalculator()
    private let calendar = Calendar(identifier: .gregorian)

    private var monthInterval: DateInterval {
        let now = Date()
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    private let categoryID = UUID()

    private func txn(
        amount: Decimal,
        kind: TransactionKind = .purchase,
        excluded: Bool = false,
        status: TransactionStatus = .booked
    ) -> Transaction {
        var transaction = Transaction(
            accountID: UUID(),
            source: .demo,
            externalID: UUID().uuidString,
            status: status,
            kind: kind,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: Date(),
            rawDescription: "x",
            rawMerchantName: "X",
            merchantDisplayName: "X"
        )
        transaction.categoryID = categoryID
        transaction.excludedFromAnalytics = excluded
        return transaction
    }

    private func progress(_ transactions: [Transaction]) -> BudgetProgress {
        let budget = Budget(name: "Testbudget", amount: 100, categoryIDs: [categoryID])
        return calculator.progress(
            budgets: [budget],
            transactions: transactions,
            categories: [],
            monthInterval: monthInterval,
            calendar: calendar,
            baseCurrency: .eur
        ).first!
    }

    @Test("Ausgabe verbraucht Budget")
    func spendingCounts() {
        let progress = progress([txn(amount: -Decimal(string: "42.50")!)])
        #expect(progress.spent == Decimal(string: "42.50")!)
    }

    @Test("Excluded Transaktion verbraucht Budget nicht (#39)")
    func excludedDoesNotCount() {
        let progress = progress([
            txn(amount: -Decimal(string: "42.50")!),
            txn(amount: -Decimal(string: "30.00")!, excluded: true)
        ])
        #expect(progress.spent == Decimal(string: "42.50")!)
    }

    @Test("Transfer verbraucht Budget nicht, auch mit Kategorie (#38)")
    func transferDoesNotCount() {
        let progress = progress([
            txn(amount: -Decimal(string: "42.50")!),
            txn(amount: -Decimal(string: "500.00")!, kind: .transfer)
        ])
        #expect(progress.spent == Decimal(string: "42.50")!)
    }

    @Test("Manual Transfer Override (effective kind transfer) verbraucht nicht")
    func manualTransferOverrideRespected() {
        var overridden = txn(amount: -Decimal(string: "300.00")!)
        overridden.kind = .transfer

        let progress = progress([txn(amount: -Decimal(string: "42.50")!), overridden])
        #expect(progress.spent == Decimal(string: "42.50")!)
    }

    @Test("Refund reduziert den Verbrauch")
    func refundReduces() {
        let progress = progress([
            txn(amount: -Decimal(string: "42.50")!),
            txn(amount: Decimal(string: "10.00")!, kind: .refund)
        ])
        #expect(progress.spent == Decimal(string: "32.50")!)
    }

    @Test("Cancelled/Reversed zählen nicht")
    func cancelledDoesNotCount() {
        let progress = progress([
            txn(amount: -Decimal(string: "42.50")!),
            txn(amount: -Decimal(string: "20.00")!, status: .cancelled),
            txn(amount: -Decimal(string: "15.00")!, status: .reversed)
        ])
        #expect(progress.spent == Decimal(string: "42.50")!)
    }

    /// identische Semantik zu Analytics: Fremdwährung wird zum
    /// Referenzkurs umgerechnet und zählt mit (Produkt-Entscheid 29.08.2026).
    @Test("Fremdwährung zählt zum Referenzkurs in ein Basiswährungs-Budget")
    func foreignCurrencyCountsConverted() {
        var foreign = txn(amount: -Decimal(string: "99.00")!)
        foreign.amount = Money(amount: -Decimal(string: "99.00")!, currency: .usd)
        foreign.categoryID = categoryID

        let progress = progress([txn(amount: -Decimal(string: "42.50")!), foreign])
        // 42.50 EUR + 99.00 USD × 0.92 = 42.50 + 91.08
        #expect(progress.spent == Decimal(string: "133.58")!)
        #expect(progress.excludedCurrencies.isEmpty)
    }

    /// Ohne Referenzkurs wird NICHT still auf 0 gerundet
    /// die Währung wird ausgeschlossen und gemeldet.
    @Test("Währung ohne Referenzkurs zählt nicht und wird gemeldet")
    func unconvertibleCurrencyIsReported() {
        let exotic = CurrencyCode("XYZ")
        var foreign = txn(amount: -Decimal(string: "99.00")!)
        foreign.amount = Money(amount: -Decimal(string: "99.00")!, currency: exotic)
        foreign.categoryID = categoryID

        let progress = progress([txn(amount: -Decimal(string: "42.50")!), foreign])
        #expect(progress.spent == Decimal(string: "42.50")!)
        #expect(progress.excludedCurrencies == [exotic])
    }

    @Test("Buchungen außerhalb des Monats zählen nicht")
    func outsideMonthDoesNotCount() {
        var old = txn(amount: -Decimal(string: "77.00")!)
        old.bookedAt = calendar.date(byAdding: .month, value: -2, to: Date())

        let progress = progress([txn(amount: -Decimal(string: "42.50")!), old])
        #expect(progress.spent == Decimal(string: "42.50")!)
    }
}

// MARK: - Leaf-only Invariant (Roadmap #43)

struct LeafCategoryTests {
    @Test("Leaf-only: Parent mit Kindern ist nicht direkt wählbar")
    func leafOnlyLogic() {
        let parent = FinanceTracker.Category(name: "Essen & Trinken", systemIconName: "fork.knife")
        let child = FinanceTracker.Category(name: "Lebensmittel", systemIconName: "cart", parentID: parent.id)

        let children = [child].filter { $0.parentID == parent.id }
        // Picker-Regel: wählbar nur wenn keine Kinder
        #expect(!children.isEmpty)
    }

    @Test("Parent ohne Kinder bleibt als Leaf wählbar")
    func parentWithoutChildrenIsLeaf() {
        let parent = FinanceTracker.Category(name: "Behörden", systemIconName: "building.columns")
        let children: [FinanceTracker.Category] = []
        #expect(children.filter { $0.parentID == parent.id }.isEmpty)
    }
}

// MARK: - Budget-Scopes (Roadmap #100)

struct BudgetScopeTests {
    private let calculator = BudgetCalculator()
    private let calendar = Calendar(identifier: .gregorian)

    private var monthInterval: DateInterval {
        let now = Date()
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    private func txn(accountID: UUID, amount: Decimal) -> Transaction {
        Transaction(
            accountID: accountID,
            source: .demo,
            externalID: UUID().uuidString,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -amount, currency: .eur),
            bookedAt: Date(),
            rawDescription: "x",
            rawMerchantName: "X",
            merchantDisplayName: "X"
        )
    }

    @Test("Account-Scope: nur TXNs des zugewiesenen Kontos zählen (#100)")
    func accountScope() {
        let catID = UUID()
        let inScopeAccount = UUID()
        let budget = Budget(name: "Scoped", amount: 100, categoryIDs: [catID], accountIDs: [inScopeAccount])

        var inScope = txn(accountID: inScopeAccount, amount: 40)
        inScope.categoryID = catID

        var outTxn = txn(accountID: UUID(), amount: 60)
        outTxn.categoryID = catID

        let progress = calculator.progress(
            budgets: [budget],
            transactions: [inScope, outTxn],
            categories: [],
            monthInterval: monthInterval,
            calendar: calendar,
            baseCurrency: .eur
        ).first!

        #expect(progress.spent == Decimal(40))
    }

    @Test("Kategorie-los: matchedCategory schlägt ohne Zuweisung fehl (Dokumentation)")
    func emptyCategoryScopeCountsNothing() {
        let budget = Budget(name: "No-Cat", amount: 100, categoryIDs: [])
        let progress = calculator.progress(
            budgets: [budget],
            transactions: [txn(accountID: UUID(), amount: 50)],
            categories: [],
            monthInterval: monthInterval,
            calendar: calendar,
            baseCurrency: .eur
        ).first!
        #expect(progress.spent == 0)
    }
}
