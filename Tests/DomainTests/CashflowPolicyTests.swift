import Foundation
import Testing

@testable import FinanceTracker

@Suite("CashflowPolicy")
struct CashflowPolicyTests {
    private let policy = CashflowPolicy()
    private let calculator = AnalyticsCalculator(baseCurrency: .eur)
    private let calendar = Calendar(identifier: .gregorian)
    private let accountID = UUID()

    private func txn(kind: TransactionKind, amount: Decimal, day: Int = 5) -> Transaction {
        Transaction(
            accountID: accountID,
            source: .etherFiCashCSV,
            status: .booked,
            kind: kind,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: day))
        )
    }

    @Test("Transfer zählt weder als Ausgabe noch als Einnahme")
    func transferIsNeutral() {
        let transactions = [
            txn(kind: .transfer, amount: -1000, day: 1),
            txn(kind: .transfer, amount: 1000, day: 2)
        ]

        let snapshot = calculator.snapshot(transactions: transactions, categories: [], calendar: calendar)

        #expect(snapshot.totalSpending == 0)
        #expect(snapshot.totalIncome == 0)
        #expect(snapshot.transactionCount == 2)
    }

    @Test("Refund und Cashback reduzieren Spending statt Income zu erzeugen")
    func refundsReduceSpending() {
        let transactions = [
            txn(kind: .purchase, amount: -50),
            txn(kind: .refund, amount: 20),
            txn(kind: .cashback, amount: 5)
        ]

        let snapshot = calculator.snapshot(transactions: transactions, categories: [], calendar: calendar)

        #expect(snapshot.totalSpending == 25)
        #expect(snapshot.totalIncome == 0)
    }

    @Test("Gebühren zählen als Ausgabe, Einkommen als Einnahme")
    func feesAndIncome() {
        let transactions = [
            txn(kind: .fee, amount: -2.50),
            txn(kind: .income, amount: 2850)
        ]

        let snapshot = calculator.snapshot(transactions: transactions, categories: [], calendar: calendar)

        #expect(snapshot.totalSpending == Decimal(string: "2.50")!)
        #expect(snapshot.totalIncome == 2850)
    }

    @Test("Unknown-Kind fällt auf Betragsvorzeichen zurück")
    func unknownFallsBackToSign() {
        let transactions = [
            txn(kind: .unknown, amount: -10),
            txn(kind: .unknown, amount: 30)
        ]

        let snapshot = calculator.snapshot(transactions: transactions, categories: [], calendar: calendar)

        #expect(snapshot.totalSpending == 10)
        #expect(snapshot.totalIncome == 30)
    }

    @Test("Erstattungsüberschuss bleibt in Nettoausgaben und Cashflow erhalten")
    func refundSurplusRemainsSigned() {
        let transactions = [
            txn(kind: .refund, amount: 100)
        ]

        let snapshot = calculator.snapshot(transactions: transactions, categories: [], calendar: calendar)

        #expect(snapshot.totalSpending == -100)
        #expect(snapshot.netCashflow == 100)
        #expect(snapshot.totalIncome == 0)
    }

    @Test("Monatspunkte respektieren die Policy (Transfer ausgeschlossen)")
    func monthlyPointsRespectPolicy() {
        let transactions = [
            txn(kind: .transfer, amount: -500, day: 1),
            txn(kind: .income, amount: 2000, day: 28),
            txn(kind: .purchase, amount: -300, day: 10)
        ]

        let points = calculator.monthlyPoints(
            transactions: transactions,
            monthsBack: 1,
            calendar: calendar,
            referenceDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        )

        #expect(points.count == 1)
        #expect(points[0].income == 2000)
        #expect(points[0].spending == 300)
    }

    @Test("Breakdowns enthalten nur konsumtive Ausgaben")
    func breakdownsExcludeRefundsAndTransfers() {
        let groceries = Category(name: "Lebensmittel", systemIconName: "cart")
        let transactions = [
            txn(kind: .purchase, amount: -40),
            txn(kind: .transfer, amount: -900),
            txn(kind: .refund, amount: 15)
        ].map { var t = $0; t.categoryID = groceries.id; return t }

        let snapshot = calculator.snapshot(
            transactions: transactions,
            categories: [groceries],
            calendar: calendar
        )

        #expect(snapshot.spendingByCategory.count == 1)
        #expect(snapshot.spendingByCategory.first?.amount == 40)
        #expect(snapshot.spendingByMerchant.count == 1)
    }
    @Test("Monatsverlauf und Kennzahlen verwenden dieselben Ausschlüsse und Erstattungen")
    func monthlyAndSnapshotParity() {
        var excluded = txn(kind: .purchase, amount: -500)
        excluded.excludedFromAnalytics = true
        let transactions = [excluded, txn(kind: .refund, amount: 100)]
        let snapshot = calculator.snapshot(transactions: transactions, categories: [])
        let points = calculator.monthlyPoints(
            transactions: transactions, monthsBack: 1, calendar: calendar,
            referenceDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        )
        #expect(snapshot.transactionCount == 1)
        #expect(points.first?.spending == snapshot.totalSpending)
        #expect(points.first?.spending == -100)
    }

    @Test("Ausgeschlossene oder stornierte Fremdwährungen erzeugen keine FX-Warnung")
    func excludedForeignDiagnostics() {
        var excluded = txn(kind: .purchase, amount: -500)
        excluded.excludedFromAnalytics = true
        excluded.amount = Money(amount: -500, currency: .usd)
        var cancelled = excluded
        cancelled.excludedFromAnalytics = false
        cancelled.status = .cancelled
        let snapshot = calculator.snapshot(transactions: [excluded, cancelled], categories: [])
        #expect(snapshot.transactionCount == 0)
        #expect(snapshot.convertedForeignTransactionCount == 0)
        #expect(snapshot.excludedForeignTransactionCount == 0)
        #expect(snapshot.convertedCurrencies.isEmpty)
        #expect(snapshot.excludedCurrencies.isEmpty)
    }

}
