import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@MainActor
@Suite("MerchantDetailModel")
struct MerchantDetailModelTests {
    /// Kein Netzwerk im Test: Der Provider fällt deterministisch auf die
    /// statischen Referenzkurse zurück (100 USD × 0.92 = 92 EUR).
    struct FailingTransport: HTTPTransport, Sendable {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw URLError(.notConnectedToInternet)
        }
    }

    @Test("Händlerdetail übernimmt Analyse-Scope, effektive Semantik und Basiswährung")
    func inheritsAnalyticsScopeAndSemantics() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(
            container: store.container,
            baseCurrency: .eur,
            fxRateProvider: ECBFXRateProvider(transport: FailingTransport(), cacheURL: nil)
        )

        let selectedAccount = Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        let otherAccount = Account(name: "Karte", type: .creditCard, currency: .eur, source: .demo)
        try await dependencies.accountRepository.upsert([selectedAccount, otherAccount])

        let parent = Category(name: "Alltag", systemIconName: "basket", colorToken: .orange)
        let child = Category(name: "Einkauf", systemIconName: "cart", colorToken: .green, parentID: parent.id)
        let otherCategory = Category(name: "Reisen", systemIconName: "airplane", colorToken: .teal)
        try await dependencies.categoryRepository.upsert([parent, child, otherCategory])

        func expense(
            _ amount: Decimal,
            currency: CurrencyCode = .eur,
            accountID: UUID? = nil,
            source: TransactionSource = .demo,
            categoryID: UUID? = nil,
            date: Date = Date(),
            merchant: String = "Markt"
        ) -> Transaction {
            Transaction(
                accountID: accountID ?? selectedAccount.id,
                source: source,
                externalID: UUID().uuidString,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -amount, currency: currency),
                bookedAt: date,
                rawMerchantName: merchant,
                merchantDisplayName: merchant,
                categoryID: categoryID ?? child.id
            )
        }

        let included = expense(40)
        let foreign = expense(100, currency: .usd)
        let excludedByUser = expense(80)
        let effectiveTransfer = expense(70)
        let outsideDate = try #require(Calendar.current.date(byAdding: .month, value: -4, to: Date()))
        try await dependencies.transactionRepository.upsert([
            included,
            foreign,
            excludedByUser,
            effectiveTransfer,
            expense(11, accountID: otherAccount.id),
            expense(12, categoryID: otherCategory.id),
            expense(13, source: .manual),
            expense(14, date: outsideDate),
            expense(15, merchant: "Anderer Markt")
        ])
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(transactionID: excludedByUser.id, excludedFromAnalytics: true),
            TransactionAnnotation(transactionID: effectiveTransfer.id, manualKindOverride: .transfer)
        ])

        let analytics = AnalyticsModel(dependencies: dependencies)
        analytics.range = .last3Months
        analytics.filterAccountIDs = [selectedAccount.id]
        analytics.filterCategoryIDs = [parent.id]
        analytics.filterSource = .demo
        await analytics.load()

        let merchant = try #require(analytics.topMerchants.first { $0.name == "Markt" })
        let scope = try #require(analytics.scope)
        // 40 EUR + 100 USD × 0.92 (Referenzkurs) = 132 EUR
        #expect(merchant.amount == 132)
        #expect(scope.query.accountIDs == [selectedAccount.id])
        #expect(scope.query.categoryIDs == [parent.id, child.id])
        #expect(scope.query.sources == [.demo])
        #expect(scope.query.dateInterval != nil)
        #expect(analytics.displayedMonthlyPoints.count == 1)

        let detail = MerchantDetailModel(
            merchantName: merchant.name,
            scope: scope,
            dependencies: dependencies
        )
        await detail.load()

        #expect(detail.total == merchant.amount)
        #expect(detail.transactionCount == 2)
        #expect(Set(detail.transactions.map(\.id)) == [included.id, foreign.id])
        #expect(detail.convertedCurrencies == [.usd])
        #expect(detail.excludedCurrencies.isEmpty)
        #expect(detail.currency == .eur)
    }
}
