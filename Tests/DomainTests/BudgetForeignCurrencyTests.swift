import Foundation
import Testing

@testable import FinanceTracker

/// Budgets, Analytics und Forecast konsumieren dieselbe
/// effektive Transaktions-Semantik. Fremdwährungen werden zum Referenzkurs
/// umgerechnet (Produkt-Entscheid 29.08.2026), ohne Kurs ausgeschlossen
/// und gemeldet (§17: kein stiller Fallback).
@Suite("BudgetForeignCurrency")
struct BudgetForeignCurrencyTests {

    private let calculator = BudgetContributionCalculator()

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
    private let otherCategoryID = UUID()

    private var eurBudget: Budget {
        Budget(name: "Reisen", amount: 500, currency: .eur, categoryIDs: [categoryID])
    }

    private func txn(
        merchant: String,
        amount: Decimal,
        currency: CurrencyCode,
        day: Int,
        kind: TransactionKind = .purchase,
        categoryID: UUID?
    ) -> Transaction {
        Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .manual,
            externalID: UUID().uuidString,
            status: .booked,
            kind: kind,
            amount: Money(amount: amount, currency: currency),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 3, day: day))!,
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant,
            categoryID: categoryID
        )
    }

    // MARK: - Umrechnung

    @Test("USD-Ausgabe zählt zum Referenzkurs auf ein EUR-Budget")
    func foreignSpendingCountsConverted() {
        // 300 USD × 0.92 EUR/USD = 276 EUR
        let transactions = [
            txn(merchant: "Hotel", amount: -300, currency: .usd, day: 4, categoryID: categoryID)
        ]

        let result = calculator.result(
            budget: eurBudget,
            transactions: transactions,
            splitLines: [],
            period: period,
            calendar: calendar
        )

        #expect(result.contributions.count == 1)
        #expect(calculator.total(result.contributions) == Decimal(276))
        #expect(result.excludedCurrencies.isEmpty)
    }

    @Test("Umgerechnete Beiträge tragen ihre Ursprungswährung")
    func convertedContributionIsMarked() {
        let transactions = [
            txn(merchant: "Hotel", amount: -300, currency: .usd, day: 4, categoryID: categoryID),
            txn(merchant: "Bahn", amount: -50, currency: .eur, day: 5, categoryID: categoryID)
        ]

        let result = calculator.result(
            budget: eurBudget,
            transactions: transactions,
            splitLines: [],
            period: period,
            calendar: calendar
        )

        let byMerchant = Dictionary(
            uniqueKeysWithValues: result.contributions.map { ($0.merchantName, $0) }
        )
        #expect(byMerchant["Hotel"]?.convertedFrom == .usd)
        #expect(byMerchant["Bahn"]?.convertedFrom == nil)
    }

    @Test("Fremdwährungs-Erstattung reduziert den Verbrauch (Vorzeichen bleibt)")
    func foreignRefundReducesSpending() {
        let transactions = [
            txn(merchant: "Hotel", amount: -300, currency: .usd, day: 4, categoryID: categoryID),
            txn(merchant: "Hotel Storno", amount: 100, currency: .usd, day: 6, kind: .refund, categoryID: categoryID)
        ]

        let total = calculator.total(calculator.contributions(
            budget: eurBudget,
            transactions: transactions,
            splitLines: [],
            period: period,
            calendar: calendar
        ))

        // (300 − 100) USD × 0.92 = 184 EUR
        #expect(total == Decimal(184))
    }

    @Test("Split-Lines werden ebenfalls in die Budget-Währung umgerechnet")
    func splitLinesAreConverted() {
        let parent = txn(merchant: "Reisebüro", amount: -200, currency: .usd, day: 7, categoryID: nil)
        let lines = [
            TransactionSplitLine(parentTransactionID: parent.id, amount: 150, categoryID: categoryID),
            TransactionSplitLine(parentTransactionID: parent.id, amount: 50, categoryID: otherCategoryID)
        ]

        let result = calculator.result(
            budget: eurBudget,
            transactions: [parent],
            splitLines: lines,
            period: period,
            calendar: calendar
        )

        // Nur die Budget-Kategorie: 150 USD × 0.92 = 138 EUR
        #expect(result.contributions.count == 1)
        #expect(calculator.total(result.contributions) == Decimal(138))
        #expect(result.contributions.first?.convertedFrom == .usd)
    }

    // MARK: - Meldung ohne Referenzkurs (§17)

    @Test("Währung ohne Referenzkurs wird ausgeschlossen UND gemeldet")
    func unknownCurrencyIsReported() {
        let exotic = CurrencyCode("XYZ")
        let transactions = [
            txn(merchant: "Unbekannt", amount: -100, currency: exotic, day: 4, categoryID: categoryID),
            txn(merchant: "Bahn", amount: -50, currency: .eur, day: 5, categoryID: categoryID)
        ]

        let result = calculator.result(
            budget: eurBudget,
            transactions: transactions,
            splitLines: [],
            period: period,
            calendar: calendar
        )

        #expect(calculator.total(result.contributions) == Decimal(50))
        #expect(result.excludedCurrencies == [exotic])
    }

    @Test("Nicht passende Transaktionen erzeugen keine Fremdwährungs-Meldung")
    func unrelatedForeignTransactionIsNotReported() {
        let exotic = CurrencyCode("XYZ")
        let transactions = [
            // Falsche Kategorie → gehört nicht zu diesem Budget.
            txn(merchant: "Fremd", amount: -100, currency: exotic, day: 4, categoryID: otherCategoryID),
            // Außerhalb der Periode.
            txn(merchant: "Alt", amount: -100, currency: exotic, day: 4, categoryID: categoryID)
                .movedToPreviousYear(calendar: calendar)
        ]

        let result = calculator.result(
            budget: eurBudget,
            transactions: transactions,
            splitLines: [],
            period: period,
            calendar: calendar
        )

        #expect(result.contributions.isEmpty)
        #expect(result.excludedCurrencies.isEmpty)
    }

    @Test("BudgetProgress meldet nicht umrechenbare Währungen weiter")
    func progressCarriesExcludedCurrencies() {
        let exotic = CurrencyCode("XYZ")
        let progress = BudgetCalculator().progress(
            budgets: [eurBudget],
            transactions: [
                txn(merchant: "Unbekannt", amount: -100, currency: exotic, day: 4, categoryID: categoryID)
            ],
            categories: [],
            monthInterval: period,
            calendar: calendar
        ).first

        #expect(progress?.spent == 0)
        #expect(progress?.excludedCurrencies == [exotic])
    }

    // MARK: - §28: gleiche Semantik wie Analytics

    @Test("Budget und Analytics zählen dieselbe USD-Ausgabe gleich")
    func budgetMatchesAnalytics() {
        let category = Category(id: categoryID, name: "Reisen", systemIconName: "airplane", colorToken: .blue)
        let transactions = [
            txn(merchant: "Hotel", amount: -300, currency: .usd, day: 4, categoryID: categoryID)
        ]

        let budgetTotal = calculator.total(calculator.contributions(
            budget: eurBudget,
            transactions: transactions,
            splitLines: [],
            period: period,
            calendar: calendar
        ))

        let snapshot = AnalyticsCalculator(baseCurrency: .eur).snapshot(
            transactions: transactions,
            categories: [category],
            calendar: calendar
        )

        #expect(budgetTotal == snapshot.totalSpending)
        #expect(snapshot.spendingByCategory.first?.amount == budgetTotal)
    }
}

private extension Transaction {
    func movedToPreviousYear(calendar: Calendar) -> Transaction {
        var copy = self
        copy.bookedAt = calendar.date(byAdding: .year, value: -1, to: displayDate)
        return copy
    }
}
