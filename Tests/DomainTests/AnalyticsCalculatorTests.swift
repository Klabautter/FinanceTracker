import Foundation
import Testing

@testable import FinanceTracker

@Suite("AnalyticsCalculator")
struct AnalyticsCalculatorTests {
    private let calculator = AnalyticsCalculator(baseCurrency: .eur)
    private let accountID = UUID()
    private let categoryFood = Category(name: "Lebensmittel", systemIconName: "cart")
    private let calendar = Calendar(identifier: .gregorian)

    private func expense(_ amount: Decimal, day: Int, status: TransactionStatus = .booked, categoryID: UUID? ) -> Transaction {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = day
        return Transaction(
            accountID: accountID,
            source: .demo,
            status: status,
            amount: Money(amount: -amount, currency: .eur),
            bookedAt: calendar.date(from: components),
            rawMerchantName: "Test Merchant",
            categoryID: categoryID
        )
    }

    @Test("Einnahmen und Ausgaben werden getrennt summiert")
    func totals() {
        let transactions = [
            expense(50, day: 1, categoryID: nil),
            expense(25, day: 2, categoryID: nil),
            Transaction(
                accountID: accountID,
                source: .demo,
                amount: Money(amount: Decimal(string: "2850.00")!, currency: .eur),
                bookedAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)),
                categoryID: nil
            )
        ]

        let snapshot = calculator.snapshot(transactions: transactions, categories: [], calendar: calendar)

        #expect(snapshot.totalSpending == 75)
        #expect(snapshot.totalIncome == Decimal(string: "2850.00")!)
        #expect(snapshot.netCashflow == Decimal(string: "2775.00")!)
    }

    @Test("Reversed und Cancelled werden ignoriert")
    func ignoresReversedAndCancelled() {
        let transactions = [
            expense(50, day: 1, status: .reversed, categoryID: nil),
            expense(30, day: 2, status: .cancelled, categoryID: nil),
            expense(10, day: 3, status: .booked, categoryID: nil)
        ]

        let snapshot = calculator.snapshot(transactions: transactions, categories: [], calendar: calendar)

        #expect(snapshot.totalSpending == 10)
        #expect(snapshot.transactionCount == 1)
    }

    @Test("Fremdwährungen werden zum Referenzkurs umgerechnet und einbezogen")
    func convertsForeignCurrency() {
        let foreign = Transaction(
            accountID: accountID,
            source: .demo,
            amount: Money(amount: -999, currency: .usd),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: 4))
        )

        let snapshot = calculator.snapshot(transactions: [foreign], categories: [], calendar: calendar)

        // 999 × 0.92 (Referenzkurs USD → EUR), exakt in Decimal-Arithmetik
        #expect(snapshot.totalSpending == Decimal(string: "919.08"))
        #expect(snapshot.transactionCount == 1)
        #expect(snapshot.convertedForeignTransactionCount == 1)
        #expect(snapshot.convertedCurrencies == [.usd])
        #expect(snapshot.excludedForeignTransactionCount == 0)
        #expect(snapshot.excludedCurrencies.isEmpty)
    }

    @Test("Fremdwährung ohne Referenzkurs bleibt ausgeschlossen und wird gemeldet")
    func excludesUnknownCurrency() {
        let foreign = Transaction(
            accountID: accountID,
            source: .demo,
            amount: Money(amount: -999, currency: CurrencyCode("XYZ")),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: 4))
        )

        let snapshot = calculator.snapshot(transactions: [foreign], categories: [], calendar: calendar)

        #expect(snapshot.totalSpending == 0)
        #expect(snapshot.transactionCount == 0)
        #expect(snapshot.excludedForeignTransactionCount == 1)
        #expect(snapshot.excludedCurrencies == [CurrencyCode("XYZ")])
        #expect(snapshot.convertedForeignTransactionCount == 0)
    }

    @Test("Kategorie-Gruppierung mit Fallback für ohne Kategorie")
    func categoryGrouping() {
        let transactions = [
            expense(40, day: 1, categoryID: categoryFood.id),
            expense(20, day: 2, categoryID: categoryFood.id),
            expense(15, day: 3, categoryID: nil)
        ]

        let snapshot = calculator.snapshot(transactions: transactions, categories: [categoryFood], calendar: calendar)

        #expect(snapshot.spendingByCategory.count == 2)
        #expect(snapshot.spendingByCategory.first?.name == "Lebensmittel")
        #expect(snapshot.spendingByCategory.first?.amount == 60)
        #expect(snapshot.spendingByCategory.last?.name == AnalyticsCalculator.uncategorizedBucketName)
        #expect(snapshot.spendingByCategory.last?.amount == 15)
    }

    @Test("Monatspunkte summieren Einnahmen und Ausgaben pro Monat")
    func monthlyPoints() {
        let income = Transaction(
            accountID: accountID,
            source: .demo,
            amount: Money(amount: 2000, currency: .eur),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: 28)),
            categoryID: nil
        )
        let spending = expense(300, day: 5, categoryID: nil)

        let points = calculator.monthlyPoints(
            transactions: [income, spending],
            monthsBack: 2,
            calendar: calendar,
            referenceDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        )

        #expect(points.count == 2)
        let august = points.last
        #expect(august != nil)
        #expect(august?.income == 2000)
        #expect(august?.spending == 300)
    }

    @Test("Monatspunkte inkludieren umgerechnete Fremdwährung")
    func monthlyPointsIncludeConvertedForeign() {
        let income = Transaction(
            accountID: accountID,
            source: .demo,
            amount: Money(amount: 2000, currency: .eur),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: 28)),
            categoryID: nil
        )
        let usdSpending = Transaction(
            accountID: accountID,
            source: .demo,
            amount: Money(amount: -100, currency: .usd),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: 5)),
            categoryID: nil
        )

        let points = calculator.monthlyPoints(
            transactions: [income, usdSpending],
            monthsBack: 2,
            calendar: calendar,
            referenceDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        )

        let august = points.last
        #expect(august?.income == 2000)
        #expect(august?.spending == Decimal(string: "92.00")) // 100 USD × 0.92
    }
}
