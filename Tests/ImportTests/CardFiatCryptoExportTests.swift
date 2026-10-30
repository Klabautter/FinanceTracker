import Foundation
import Testing

@testable import FinanceTracker

/// Kartenexport mit getrennter Uhrzeit, Fiat- und Krypto-Betrag und
/// vorzeichenlosen Beträgen: Die Richtung steht nur in der Art.
@Suite("CardFiatCryptoExport")
struct CardFiatCryptoExportTests {
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

    @Test("Spalten werden an ihren Überschriften erkannt")
    func detectsColumns() throws {
        let document = try CSVReader.parse(fixtureData("fixture_card_fiat_crypto"))
        let mapping = try #require(GenericCSVMapping.detect(in: document))
        #expect(mapping.dateColumn == "date")
        #expect(mapping.timeColumn == "time")
        #expect(mapping.amountColumn == "fiat amount")
        #expect(mapping.currencyColumn == "fiat currency")
        #expect(mapping.typeColumn == "type")
        #expect(mapping.externalIDColumn == "reference")
        #expect(mapping.cryptoAmountColumn == "crypto amount")
    }

    @Test("Vorzeichenlose Beträge: Kauf und Gebühr gehen ab, Erstattung und Cashback kommen an")
    func signSemantics() async throws {
        let result = try await provider.parse(ImportFile(fileName: nil, data: fixtureData("fixture_card_fiat_crypto")))
        func row(_ reference: String) throws -> ImportedTransaction {
            try #require(result.transactions.first { $0.externalID == reference })
        }

        #expect(try row("mm-1001").kind == .purchase)
        #expect(try row("mm-1001").amount.amount == Decimal(string: "-18.30")!)
        #expect(try row("mm-1003").kind == .refund)
        #expect(try row("mm-1003").amount.amount == Decimal(string: "16.49")!)
        #expect(try row("mm-1006").kind == .fee)
        #expect(try row("mm-1006").amount.amount == Decimal(string: "-1.00")!)
        #expect(try row("mm-1007").kind == .cashback)
        #expect(try row("mm-1007").amount.amount == Decimal(string: "2.50")!)
    }

    @Test("Fixture-Parse: Status, Uhrzeit, Krypto-Angaben, Zeilenfehler, unbekannte Arten")
    func parsesFixture() async throws {
        let result = try await provider.parse(ImportFile(fileName: nil, data: fixtureData("fixture_card_fiat_crypto")))

        // 9 Datenzeilen, 1 unlesbarer Betrag.
        #expect(result.totalRows == 9)
        #expect(result.transactions.count == 8)
        #expect(result.issues.map(\.rowIndex) == [8])

        let mcdonalds = try #require(result.transactions.first { $0.externalID == "mm-1001" })
        #expect(mcdonalds.amount.currency == .eur)
        #expect(mcdonalds.cryptoAsset == "USDC")
        #expect(mcdonalds.cryptoAmount == Decimal(string: "18.31")!)
        #expect(mcdonalds.status == .booked)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.hour, .minute], from: try #require(mcdonalds.bookedAt))
        #expect(parts.hour == 9 && parts.minute == 10)

        let pending = try #require(result.transactions.first { $0.externalID == "mm-1004" })
        #expect(pending.status == .pending)
        #expect(pending.bookedAt == nil)
        #expect(pending.authorizedAt != nil)

        let declined = try #require(result.transactions.first { $0.externalID == "mm-1005" })
        #expect(declined.status == .cancelled)

        // „PENDING“ und „DECLINED“ stehen in der Art-Spalte: unbekannt, die
        // Vorschau fragt nach.
        #expect(Set(result.unknownTypes.map(\.key)) == ["PENDING", "DECLINED"])
    }

    @Test("Import-Pipeline E2E: Import, Dedup bei Re-Import, Analytics wirksam")
    func pipelineE2E() async throws {
        let dependencies = try makeDependenciesForE2E()
        let pipeline = makePipeline(dependencies)
        let file = try ImportFile(fileName: nil, data: fixtureData("fixture_card_fiat_crypto"))

        try await dependencies.accountRepository.upsert([
            Account(name: "Karte", type: .creditCard, currency: .eur, source: .manual)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let detected = try await pipeline.detectProvider(for: file)
        #expect(detected?.identifier == GenericCSVProvider.providerIdentifier)

        let firstRun = try await pipeline.run(file, into: account.id)
        #expect(firstRun.importedCount == 8)
        #expect(firstRun.duplicateCount == 0)
        #expect(firstRun.failedCount == 1)

        let secondRun = try await pipeline.run(file, into: account.id)
        #expect(secondRun.importedCount == 0)
        #expect(secondRun.duplicateCount == 8)
        #expect(try await dependencies.transactionRepository.count() == 8)

        let all = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let snapshot = AnalyticsCalculator(baseCurrency: .eur).snapshot(transactions: all, categories: [], calendar: .current)
        #expect(snapshot.totalSpending > 0)
    }
}
