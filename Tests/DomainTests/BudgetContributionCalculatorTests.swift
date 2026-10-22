import Foundation
import Testing

@testable import FinanceTracker

/// WP9: Budget-Detail nutzt exakt dieselbe Finance-Semantik wie der
/// Budget-Header (gemeinsame Contribution-Pipeline).
private extension Transaction {
    func withCategory(_ categoryID: UUID) -> Transaction {
        var copy = self
        copy.categoryID = categoryID
        return copy
    }
}

@Suite("BudgetContributionCalculator")
struct BudgetContributionCalculatorTests {

    private let calculator = BudgetContributionCalculator()

    private let dec50 = Decimal(string: "50.00")!
    private let dec20 = Decimal(string: "20.00")!
    private let dec30 = Decimal(string: "30.00")!
    private let dec40 = Decimal(string: "40.00")!
    private let dec55 = Decimal(string: "55.00")!
    private let dec60 = Decimal(string: "60.00")!
    private let dec75 = Decimal(string: "75.00")!
    private let dec90 = Decimal(string: "90.00")!
    private let dec100 = Decimal(string: "100.00")!
    private let dec120 = Decimal(string: "120.00")!
    private let dec250 = Decimal(string: "250.00")!
    private let dec500 = Decimal(string: "500.00")!
    private let dec1000 = Decimal(string: "1000.00")!
    private let dec400 = Decimal(string: "400.00")!


    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    private var period: DateInterval {
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    private let categoryID = UUID()

    private var budget: Budget {
        Budget(name: "Test", amount: 500, categoryIDs: [categoryID])
    }

    private func txn(
        merchant: String,
        amount: Decimal,
        day: Int,
        status: TransactionStatus = .booked,
        kind: TransactionKind = .purchase,
        categoryID: UUID? = nil
    ) -> Transaction {
        Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .demo,
            externalID: UUID().uuidString,
            status: status,
            kind: kind,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 3, day: day))!,
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant,
            categoryID: categoryID
        )
    }

    @Test("Header == Trend: Summe der Contributions")
    func totalEqualsSum() {
        let transactions = [
            txn(merchant: "A", amount: -dec50, day: 2, categoryID: categoryID),
            txn(merchant: "B", amount: -dec30, day: 5, categoryID: categoryID),
            txn(merchant: "C", amount: -dec20, day: 9, categoryID: categoryID)
        ]
        let contributions = calculator.contributions(
            budget: budget,
            transactions: transactions,
            splitLines: [],
            period: period,
            calendar: calendar
        )
        #expect(contributions.count == 3)
        #expect(calculator.total(contributions) == dec100)
    }

    @Test("Excluded → kein Beitrag")
    func excludedIgnored() {
        let excluded = Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .demo,
            externalID: UUID().uuidString,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -100, currency: .eur),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 3, day: 2))!,
            rawDescription: "Sonderzahlung",
            rawMerchantName: "Sonderzahlung",
            merchantDisplayName: "Sonderzahlung",
            excludedFromAnalytics: true
        )

        let contributions = calculator.contributions(
            budget: budget,
            transactions: [excluded],
            splitLines: [],
            period: period,
            calendar: calendar
        )
        #expect(contributions.isEmpty)
        #expect(calculator.total(contributions) == 0)
    }

    @Test("Manual transfer → kein Beitrag")
    func manualTransferIgnored() {
        let raw = txn(merchant: "Umbuchung", amount: -dec500, day: 3)
        let annotation = TransactionAnnotation(transactionID: raw.id, manualKindOverride: .transfer)
        let transfer = EffectiveTransactionResolver().applying(annotations: [annotation], to: [raw])

        let contributions = calculator.contributions(
            budget: budget,
            transactions: transfer,
            splitLines: [],
            period: period,
            calendar: calendar
        )
        #expect(calculator.total(contributions) == 0)
    }

    @Test("Detected transfer → kein Beitrag")
    func detectedTransferIgnored() {
        let transfer = txn(merchant: "Kontoübertrag", amount: -dec250, day: 4, kind: .transfer)

        let contributions = calculator.contributions(
            budget: budget,
            transactions: [transfer],
            splitLines: [],
            period: period,
            calendar: calendar
        )
        #expect(calculator.total(contributions) == 0)
    }

    @Test("Refund reduziert den Verbrauch lt. Policy")
    func refundReduces() {
        let purchase = txn(merchant: "Kauf", amount: -dec100, day: 2)
        let refund = txn(merchant: "Rückerstattung", amount: dec40, day: 8, kind: .refund)

        let contributions = calculator.contributions(
            budget: budget,
            transactions: [
                purchase.withCategory(categoryID),
                refund.withCategory(categoryID)
            ],
            splitLines: [],
            period: period,
            calendar: calendar
        )
        #expect(calculator.total(contributions) == dec60)
    }

    @Test("Split-Erstattung kehrt die Budget-Beiträge der Split-Lines um")
    func splitRefundReducesBudget() {
        let purchase = txn(merchant: "Kauf", amount: -dec100, day: 2)
        let refund = txn(merchant: "Rückerstattung", amount: dec20, day: 8, kind: .refund)
        let splitLines = [
            TransactionSplitLine(parentTransactionID: purchase.id, amount: 60),
            TransactionSplitLine(parentTransactionID: purchase.id, amount: 40),
            TransactionSplitLine(parentTransactionID: refund.id, amount: 12),
            TransactionSplitLine(parentTransactionID: refund.id, amount: 8)
        ]
        let salaryBudget = Budget(
            name: "Gehalt-zu-Gehalt",
            amount: 500,
            periodPolicy: .salaryCycle(recurringIncomeID: UUID())
        )

        let contributions = calculator.contributions(
            budget: salaryBudget,
            transactions: [purchase, refund],
            splitLines: splitLines,
            period: period,
            calendar: calendar
        )

        #expect(contributions.count == 4)
        #expect(calculator.total(contributions) == 80)
    }

    @Test("Split: Parent zählt nicht zusätzlich, Split-Lines erscheinen einzeln")
    func splitLines() {
        let lineCategory = UUID()
        let parent = txn(merchant: "Großhandel", amount: -dec90, day: 6)
        let splitLines = [
            TransactionSplitLine(parentTransactionID: parent.id, amount: 60, categoryID: lineCategory),
            TransactionSplitLine(parentTransactionID: parent.id, amount: 30, categoryID: nil, note: "Rest")
        ]

        let contributions = calculator.contributions(
            budget: budget,
            transactions: [parent],
            splitLines: splitLines,
            period: period,
            calendar: calendar
        )
        // Beide Lines zählen (Budget ohne categoryIDs → coversAll bei salary? Nein:
        // normales Budget mit categoryIDs=[] zählt keine Lines mit categoryID
        // hier: budget.categoryIDs.isEmpty && isSalaryCycle == false → coversAll false;
        // line 1 hat categoryID → nicht enthalten; line 2 (nil) → nicht enthalten.
        // Der Parent selbst wird NICHT gezählt (Split-Parent).
        #expect(contributions.isEmpty)

        // Budget MIT passender Kategorie zählt nur die passende Line:
        let categorizedBudget = Budget(name: "Kat", amount: 500, categoryIDs: [lineCategory])
        let categorizedContributions = calculator.contributions(
            budget: categorizedBudget,
            transactions: [parent],
            splitLines: splitLines,
            period: period,
            calendar: calendar
        )
        #expect(categorizedContributions.count == 1)
        #expect(calculator.total(categorizedContributions) == 60)

        // Salary-Cycle-Budget ohne Kategorien zählt alle Split-Lines:
        let salaryBudget = Budget(
            name: "Gehalt-zu-Gehalt",
            amount: 500,
            periodPolicy: .salaryCycle(recurringIncomeID: UUID())
        )
        let salaryContributions = calculator.contributions(
            budget: salaryBudget,
            transactions: [parent],
            splitLines: splitLines,
            period: period,
            calendar: calendar
        )
        #expect(salaryContributions.count == 2)
        #expect(calculator.total(salaryContributions) == 90)
        #expect(salaryContributions.allSatisfy { $0.isSplitLine })
    }

    @Test("Reversed → ausgeschlossen")
    func reversedExcluded() {
        let reversed = txn(merchant: "Storniert", amount: -dec75, day: 3, status: .reversed)
        let contributions = calculator.contributions(
            budget: budget,
            transactions: [reversed],
            splitLines: [],
            period: period,
            calendar: calendar
        )
        #expect(contributions.isEmpty)
    }

    @Test("Transaktion außerhalb der Periode → kein Beitrag")
    func outsidePeriodExcluded() {
        let old = Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .demo,
            externalID: UUID().uuidString,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -dec60, currency: .eur),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 2, day: 10))!,
            rawDescription: "Alt",
            rawMerchantName: "Alt",
            merchantDisplayName: "Alt"
        )
        let contributions = calculator.contributions(
            budget: budget,
            transactions: [old],
            splitLines: [],
            period: period,
            calendar: calendar
        )
        #expect(contributions.isEmpty)
    }

    @Test("Header-Konsistenz: BudgetCalculator.progress == Contribution-Summe")
    func progressMatchesContributions() {
        let categoryID = UUID()
        let budget = Budget(name: "Kat", amount: 400, categoryIDs: [categoryID])
        let transactions = [
            txn(merchant: "Einkauf", amount: -dec120, day: 3),
            txn(merchant: "Transfer", amount: -Decimal(string: "900.00")!, day: 4, kind: .transfer),
            txn(merchant: "Refund", amount: dec20, day: 6, kind: .refund, categoryID: categoryID),
            txn(merchant: "Reversed", amount: -dec55, day: 7, status: .reversed)
        ].map { transaction -> Transaction in
            var copy = transaction
            copy.categoryID = categoryID
            return copy
        }

        let progress = BudgetCalculator().progress(
            budgets: [budget],
            transactions: transactions,
            categories: [],
            monthInterval: period,
            calendar: calendar
        )
        let contributions = calculator.contributions(
            budget: budget,
            transactions: transactions,
            splitLines: [],
            period: period,
            calendar: calendar
        )

        #expect(progress.first?.spent == calculator.total(contributions))
        #expect(progress.first?.spent == dec100) // 120 − 20, Transfer/Reversed ausgeschlossen
    }
}
