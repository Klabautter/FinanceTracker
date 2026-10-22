import Foundation
import Testing

@testable import FinanceTracker

struct AnalyticsSplitTests {
    @Test("Fremdwährungs-Splits bleiben in Basiswährung und Parent zählt einmal")
    func foreignCurrencySplitsStayConvertedAndCountParentOnce() {
        let eurPerUSD = Decimal(string: "0.90")!
        let calculator = AnalyticsCalculator(
            baseCurrency: .eur,
            converter: CurrencyConverter(eurPerUnit: [CurrencyCode("USD"): eurPerUSD])
        )
        let foodID = UUID()
        let householdID = UUID()
        let parent = Transaction(
            accountID: UUID(),
            source: .demo,
            status: .pending,
            kind: .purchase,
            amount: Money(amount: -Decimal(100), currency: CurrencyCode("USD")),
            bookedAt: Date(),
            rawDescription: "Foreign split purchase",
            rawMerchantName: "Shop",
            categoryID: foodID
        )
        let lines = [
            TransactionSplitLine(parentTransactionID: parent.id, amount: 60, categoryID: foodID),
            TransactionSplitLine(parentTransactionID: parent.id, amount: 40, categoryID: householdID)
        ]

        let snapshot = calculator.snapshot(
            transactions: [parent],
            categories: [
                Category(id: foodID, name: "Food", systemIconName: "cart"),
                Category(id: householdID, name: "Household", systemIconName: "house")
            ],
            calendar: .current,
            splitLines: lines
        )

        #expect(snapshot.totalSpending == 90)
        #expect(snapshot.pendingAmount == 90)
        #expect(snapshot.pendingCount == 1)
        #expect(snapshot.transactionCount == 1)
        #expect(snapshot.spendingByCategory.first { $0.categoryID == foodID }?.amount == 54)
        #expect(snapshot.spendingByCategory.first { $0.categoryID == householdID }?.amount == 36)
        #expect(snapshot.spendingByMerchant.first?.amount == 90)
    }

    @Test("Kategorie-Breakdown nutzt Split-Lines statt Parent; Summen bleiben erhalten")
    func splitBreakdown() {
        let calculator = AnalyticsCalculator(baseCurrency: .eur)
        let calendar = Calendar(identifier: .gregorian)

        let catLebensmittel = UUID()
        let catDrogerie = UUID()
        let categories = [
            Category(id: catLebensmittel, name: "Lebensmittel", systemIconName: "cart"),
            Category(id: catDrogerie, name: "Drogerie", systemIconName: "pills")
        ]

        let parent = Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .demo,
            externalID: "split-a",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(string: "85.00")!, currency: .eur),
            bookedAt: calendar.date(from: calendar.dateComponents([.year, .month, .day], from: Date())),
            rawDescription: "REWE",
            rawMerchantName: "REWE",
            merchantDisplayName: "REWE",
            categoryID: catLebensmittel
        )

        let lines = [
            TransactionSplitLine(parentTransactionID: parent.id, amount: Decimal(string: "60.00")!, categoryID: catLebensmittel),
            TransactionSplitLine(parentTransactionID: parent.id, amount: Decimal(string: "25.00")!, categoryID: catDrogerie)
        ]

        let snapshot = calculator.snapshot(
            transactions: [parent],
            categories: categories,
            calendar: calendar,
            splitLines: lines
        )

        // Kategorie-Breakdown über Split-Lines
        let lebensmittel = snapshot.spendingByCategory.first { $0.categoryID == catLebensmittel }
        let drogerie = snapshot.spendingByCategory.first { $0.categoryID == catDrogerie }
        #expect(lebensmittel?.amount == Decimal(string: "60.00")!)
        #expect(drogerie?.amount == Decimal(string: "25.00")!)

        // Gesamtsumme bleibt erhalten (keine Doppelzählung des Parents)
        #expect(snapshot.totalSpending == Decimal(string: "85.00")!)

        // Merchant-Breakdown bleibt beim Parent-Merchant
        #expect(snapshot.spendingByMerchant.first?.name == "REWE")
        #expect(snapshot.spendingByMerchant.first?.amount == Decimal(string: "85.00")!)

        // Ohne Splits: Parent-Kategorie zählt voll (Regression)
        let snapshotWithoutSplits = calculator.snapshot(
            transactions: [parent],
            categories: categories,
            calendar: calendar
        )
        #expect(snapshotWithoutSplits.spendingByCategory.first { $0.categoryID == catLebensmittel }?.amount == Decimal(string: "85.00")!)
    }

    @Test("Excluded Parent schließt seine Split-Lines aus")
    func excludedParentExcludesLines() {
        let calculator = AnalyticsCalculator(baseCurrency: .eur)
        let parent = Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .demo,
            externalID: "split-excl",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(string: "50.00")!, currency: .eur),
            bookedAt: Date(),
            rawDescription: "x",
            rawMerchantName: "X",
            merchantDisplayName: "X",
            excludedFromAnalytics: true
        )
        let lines = [
            TransactionSplitLine(parentTransactionID: parent.id, amount: Decimal(50))
        ]

        let snapshot = calculator.snapshot(
            transactions: [parent],
            categories: [],
            calendar: .current,
            splitLines: lines
        )
        #expect(snapshot.totalSpending == 0)
        #expect(snapshot.spendingByCategory.isEmpty)
    }
}
