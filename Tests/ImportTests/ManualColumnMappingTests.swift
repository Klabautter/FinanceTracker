import Foundation
import Testing

@testable import FinanceTracker

@Suite("ManualColumnMapping")
struct ManualColumnMappingTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    @Test("Forced Mapping parst Dateien ohne erkennbare Standard-Header")
    func forcedMappingParses() async throws {
        let dependencies = try makeDependencies()

        let csv = """
        Wann;Was;Wieviel;Waehrung
        05.08.2026;Kaffee Bar;-4,80;EUR
        06.08.2026;Supermarkt;-33,10;EUR
        """

        let mapping = GenericCSVMapping(
            dateColumn: "Wann",
            amountColumn: "Wieviel",
            descriptionColumn: "Was",
            merchantColumn: "Was",
            currencyColumn: "Waehrung",
            externalIDColumn: nil
        )
        let provider = GenericCSVProvider(fallbackCurrency: .eur, forcedMapping: mapping)

        let file = ImportFile(fileName: nil, data: Data(csv.utf8))
        #expect(try await provider.canHandle(file) == true)

        let parseOutcome = try await provider.parse(file)
        let parsed = parseOutcome.transactions
        #expect(parsed.count == 2)
        #expect(parsed[0].amount.amount == Decimal(string: "-4.80")!)
        #expect(parsed[0].merchantDisplayName == "Kaffee Bar")

        let pipeline = ImportPipeline(
            providers: [provider],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            fallbackCurrency: .eur
        )
        let result = try await pipeline.run(file, into: UUID())
        #expect(result.importedCount == 2)
    }

    @Test("headers(of:) liefert Spalten aus CSV und xlsx")
    func headersExtraction() async throws {
        let bundle = Bundle(for: BundleMarker.self)
        guard let url = bundle.url(forResource: "fixture_etherfi_cash", withExtension: "xlsx") else {
            throw ImportError.parsingFailed(stage: "testSetup", reason: "xlsx-Fixture nicht gefunden.")
        }
        let data = try Data(contentsOf: url)

        let pipeline = ImportPipeline(
            providers: [],
            transactionRepository: (try makeDependencies()).transactionRepository,
            fallbackCurrency: .eur
        )

        let csvHeaders = pipeline.headers(of: ImportFile(fileName: nil, data: Data("A,B\n1,2\n".utf8)))
        #expect(csvHeaders == ["A", "B"])

        let xlsxHeaders = pipeline.headers(of: ImportFile(fileName: nil, data: data))
        #expect(xlsxHeaders?.first == "timestamp")
    }

    private final class BundleMarker {}
}
