import Foundation
import Testing

@testable import FinanceTracker

/// Kartenexport mit vorzeichenlosen Beträgen, Cashback, Originalbetrag und
/// Händlerbranche.
@Suite("CardCashbackExport")
struct CardCashbackExportTests {
    private final class BundleMarker {}

    private func fixtureData(_ name: String, ext: String = "csv") throws -> Data {
        let bundle = Bundle(for: BundleMarker.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw ImportError.parsingFailed(stage: "testSetup", reason: "Fixture \(name).\(ext) nicht gefunden.")
        }
        return try Data(contentsOf: url)
    }

    private var provider: GenericCSVProvider { GenericCSVProvider(fallbackCurrency: .eur) }


    private func makeDependenciesForE2E() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(
            container: store.container,
            baseCurrency: .eur,
            importProviders: [provider]
        )
    }

    private func makePipeline(_ dependencies: AppDependencies) -> ImportPipeline {
        ImportPipeline(
            providers: dependencies.importProviders,
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )
    }

    @Test("Spalten des Kartenexports werden erkannt, inklusive Cashback und Branche")
    func detectsColumns() throws {
        let document = try CSVReader.parse(fixtureData("fixture_card_cashback"))
        let mapping = try #require(GenericCSVMapping.detect(in: document))
        #expect(mapping.dateColumn == "timestamp")
        #expect(mapping.amountColumn == "amount")
        #expect(mapping.currencyColumn == "currency")
        #expect(mapping.originalAmountColumn == "original amount")
        #expect(mapping.cashbackColumn == "cashback earned")
        #expect(mapping.merchantCategoryColumn == "category")
        #expect(mapping.merchantColumn == nil)
    }

    @Test("card_spend wird negativ normalisiert (Ausgabe), refund positiv")
    func signSemantics() async throws {
        let parseResult = try await provider.parse(try ImportFile(fileName: nil, data: fixtureData("fixture_card_cashback")))
        let transactions = parseResult.transactions

        let pendingSpend = transactions[0]
        #expect(pendingSpend.status == .pending)
        #expect(pendingSpend.kind == .purchase)
        #expect(pendingSpend.amount.amount == Decimal(string: "-18.3")!)
        #expect(pendingSpend.authorizedAt != nil)
        #expect(pendingSpend.bookedAt == nil)

        let clearedSpend = transactions[1]
        #expect(clearedSpend.kind == .purchase)
        #expect(clearedSpend.amount.amount == Decimal(string: "-16.49")!)
        #expect(clearedSpend.bookedAt != nil)

        let cancelledSpend = transactions[2]
        #expect(cancelledSpend.status == .cancelled)
        #expect(cancelledSpend.kind == .purchase)
        #expect(cancelledSpend.amount.amount == Decimal(string: "-13.19")!)

        let refund = transactions[5]
        #expect(refund.kind == .refund)
        #expect(refund.status == .booked)
        #expect(refund.amount.amount == Decimal(string: "16.49")!)
    }

    @Test("USD-Zeile bleibt in USD, Merchant getrimmt")
    func currencyAndTrimming() async throws {
        let parseResult = try await provider.parse(try ImportFile(fileName: nil, data: fixtureData("fixture_card_cashback")))
        let transactions = parseResult.transactions

        let usdRow = transactions[3]
        #expect(usdRow.amount.currency == .usd)
        #expect(usdRow.amount.amount == Decimal(string: "-7.44")!)

        #expect(transactions.allSatisfy { $0.merchantDisplayName?.hasSuffix(" ") != true })
    }

    @Test("Zeitpunkt mit UTC-Suffix wird korrekt geparst")
    func timestampParsing() async throws {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let parseResult = try await provider.parse(try ImportFile(fileName: nil, data: fixtureData("fixture_card_cashback")))
        let transactions = parseResult.transactions

        let components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: transactions[1].bookedAt!)
        #expect(components == DateComponents(year: 2026, month: 7, day: 31, hour: 6, minute: 46))
    }

    @Test("Analytics-E2E: Spends zählen als Ausgaben, nicht Einnahmen")
    func analyticsEndToEnd() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(
            container: store.container,
            baseCurrency: .eur,
            importProviders: [provider]
        )
        let pipeline = ImportPipeline(
            providers: dependencies.importProviders,
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )

        _ = try await pipeline.run(
            try ImportFile(fileName: nil, data: fixtureData("fixture_card_cashback")),
            into: UUID()
        )

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.count == 6)

        let calendar = Calendar(identifier: .gregorian)
        let calculator = AnalyticsCalculator(baseCurrency: .eur)
        let snapshot = calculator.snapshot(transactions: stored, categories: [], calendar: calendar)

        // Produkt-Entscheid 29.08.2026: Fremdwährung (7.44 USD) fließt zum
        // Referenzkurs ein: 83.94 EUR + 7.44 × 0.92 = 90.7848 EUR.
        #expect(snapshot.totalSpending == Decimal(string: "90.7848"))
        #expect(snapshot.totalIncome == 0)
    }

    @Test("Original Amount und Currency werden aus dem Export erhalten")
    func originalValuesRoundtrip() async throws {
        let dependencies = try await MainActor.run { try makeDependenciesForE2E() }
        let pipeline = makePipeline(dependencies)

        let file = try ImportFile(fileName: nil, data: fixtureData("fixture_card_cashback"))
        _ = try await pipeline.run(file, into: UUID())

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let usdRow = try #require(stored.first { $0.amount.currency == .usd })
        #expect(usdRow.originalAmount == Decimal(string: "7.44")!)
        #expect(usdRow.originalCurrency == .usd)

        let pending = try #require(stored.first { $0.status == .pending })
        #expect(pending.originalAmount == Decimal(string: "18.3")!)
        #expect(pending.originalCurrency == .eur)
    }

    @Test("Pipeline-E2E mit xlsx: Cashback, Status, Re-Import-Dedup")
    func pipelineEndToEndWithXlsx() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(
            container: store.container,
            baseCurrency: .eur,
            importProviders: [provider]
        )
        let pipeline = ImportPipeline(
            providers: dependencies.importProviders,
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )

        let accountID = UUID()
        let xlsxFile = try ImportFile(fileName: "transaction-history.xlsx", data: fixtureData("fixture_card_cashback", ext: "xlsx"))

        let firstRun = try await pipeline.run(xlsxFile, into: accountID)
        #expect(firstRun.totalRows == 6)
        #expect(firstRun.importedCount == 6)

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.count == 6)

        let pending = try #require(stored.first { $0.status == .pending })
        #expect(pending.cashbackAmount == Decimal(string: "0.55")!)
        #expect(pending.cashbackCurrency == .eur)
        #expect(pending.kind == .purchase)
        #expect(pending.amount.amount == Decimal(string: "-18.3")!)

        let secondRun = try await pipeline.run(xlsxFile, into: accountID)
        #expect(secondRun.importedCount == 0)
        #expect(secondRun.duplicateCount == 6)
    }
}
