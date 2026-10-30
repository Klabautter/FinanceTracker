import Foundation
import Testing

@testable import FinanceTracker

@Suite("PendingBookedReconciler")
struct PendingBookedReconcilerTests {
    private let reconciler = PendingBookedReconciler()
    private let accountID = UUID()

    private func pending(date: Date, amount: Decimal = -18.3) -> Transaction {
        Transaction(
            accountID: accountID,
            source: .legacyCardExportCSV,
            status: .pending,
            kind: .purchase,
            amount: Money(amount: amount, currency: .eur),
            authorizedAt: date,
            rawMerchantName: "MCDONALDS 155",
            merchantDisplayName: "MCDONALDS 155"
        )
    }

    private func booked(date: Date, amount: Decimal = -18.3, merchant: String = "MCDONALDS 155", externalID: String? = nil) -> Transaction {
        Transaction(
            accountID: accountID,
            source: .legacyCardExportCSV,
            externalID: externalID,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: date,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
    }

    @Test("Booked-Varianten matchen Pending-Kandidaten")
    func matchesCandidates() {
        let candidate = pending(date: date("2026-08-23 09:10:38"))

        #expect(reconciler.findTarget(for: booked(date: date("2026-08-24 10:00:00")), among: [candidate]) != nil)
        #expect(reconciler.findTarget(for: booked(date: date("2026-08-20 03:00:00")), among: [candidate]) != nil)
    }

    @Test("Zu große Abweichungen werden nicht gematcht")
    func rejectsNonMatches() {
        let candidate = pending(date: date("2026-08-23 09:10:38"))

        #expect(reconciler.findTarget(for: booked(date: date("2026-09-05 09:00:00")), among: [candidate]) == nil)
        #expect(reconciler.findTarget(for: booked(date: date("2026-08-24 09:00:00"), amount: -42), among: [candidate]) == nil)
        #expect(reconciler.findTarget(for: booked(date: date("2026-08-24 09:00:00"), merchant: "TOTALLY DIFFERENT SHOP"), among: [candidate]) == nil)

        var otherAccount = booked(date: date("2026-08-24 09:00:00"))
        otherAccount.accountID = UUID()
        #expect(reconciler.findTarget(for: otherAccount, among: [candidate]) == nil)
    }

    @Test("Pipeline reconciled Pending→Booked ohne Duplikat")
    func pipelineReconciles() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )
        let accountID = UUID()

        _ = try await pipeline.run(ImportFile(fileName: nil, data: pendingCSV()), into: accountID)
        #expect(try await dependencies.transactionRepository.count() == 1)

        let secondRun = try await pipeline.run(ImportFile(fileName: nil, data: bookedCSV()), into: accountID)
        #expect(secondRun.importedCount == 0)
        #expect(secondRun.updatedCount == 1)
        #expect(try await dependencies.transactionRepository.count() == 1)

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.count == 1)
        #expect(stored.first?.status == .booked)
        #expect(stored.first?.bookedAt != nil)
    }

    @Test("Pending→Booked übernimmt erst dann passende Kategorie, wenn noch keine gesetzt ist")
    func reconciliationAdoptsNewRuleCategory() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            merchantRepository: dependencies.merchantRepository,
            categoryRepository: dependencies.categoryRepository,
            fallbackCurrency: .eur
        )
        let accountID = UUID()

        _ = try await pipeline.run(ImportFile(fileName: nil, data: pendingCSV()), into: accountID)
        try await dependencies.ruleRepository.upsert([
            CategoryRule(priority: 1, condition: .merchantEquals("McDonald's"), categoryID: Category.restaurants.id)
        ])

        _ = try await pipeline.run(ImportFile(fileName: nil, data: bookedCSV()), into: accountID)

        let stored = try #require(await dependencies.transactionRepository.transactions(matching: TransactionQuery()).first)
        #expect(stored.status == .booked)
        #expect(stored.categoryID == Category.restaurants.id)
    }

    @Test("Pending→Booked bewahrt eine vorhandene Nutzerkategorie")
    func reconciliationPreservesExistingCategory() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            merchantRepository: dependencies.merchantRepository,
            categoryRepository: dependencies.categoryRepository,
            fallbackCurrency: .eur
        )
        let accountID = UUID()

        _ = try await pipeline.run(ImportFile(fileName: nil, data: pendingCSV()), into: accountID)
        var pending = try #require(await dependencies.transactionRepository.transactions(matching: TransactionQuery()).first)
        pending.categoryID = Category.groceries.id
        try await dependencies.transactionRepository.upsert([pending])
        try await dependencies.ruleRepository.upsert([
            CategoryRule(priority: 1, condition: .merchantEquals("McDonald's"), categoryID: Category.restaurants.id)
        ])

        _ = try await pipeline.run(ImportFile(fileName: nil, data: bookedCSV()), into: accountID)

        let stored = try #require(await dependencies.transactionRepository.transactions(matching: TransactionQuery()).first)
        #expect(stored.categoryID == Category.groceries.id)
    }

    @Test("Zweiter echter Kauf bleibt eigenständig")
    func distinctSecondPurchaseNotMerged() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )
        let accountID = UUID()

        _ = try await pipeline.run(ImportFile(fileName: nil, data: pendingCSV()), into: accountID)

        let otherAmountCSV = Data("""
        timestamp,type,description,status,amount,currency
        2026-08-24 12:00:00 UTC,card_spend,MCDONALDS 155,CLEARED,42,EUR
        """.utf8)
        let result = try await pipeline.run(ImportFile(fileName: nil, data: otherAmountCSV), into: accountID)

        #expect(result.importedCount == 1)
        #expect(result.updatedCount == 0)
        #expect(try await dependencies.transactionRepository.count() == 2)
    }
}

private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string.replacingOccurrences(of: " ", with: "T") + "Z")!
}

private extension PendingBookedReconcilerTests {
    func pendingCSV() -> Data {
        Data("""
        timestamp,type,description,status,amount,currency
        2026-08-23 09:10:38 UTC,card_spend,MCDONALDS 155,PENDING,18.3,EUR
        """.utf8)
    }

    func bookedCSV() -> Data {
        Data("""
        timestamp,type,description,status,amount,currency
        2026-08-24 12:00:00 UTC,card_spend,MCDONALDS 155,CLEARED,18.3,EUR
        """.utf8)
    }
}
