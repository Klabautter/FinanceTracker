import Foundation
import Testing

@testable import FinanceTracker

/// Kartenexport eines USD-Kontos: Aufladungen, Käufe mit Euro-Betrag,
/// Cashback und Gebühren in eigener Spalte, vorzeichenbehaftete Beträge.
@Suite("CardUSDLocalExport")
struct CardUSDLocalExportTests {
    private final class BundleMarker {}

    private func fixture() throws -> ImportFile {
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: "fixture_card_usd_local", withExtension: "csv"))
        return ImportFile(fileName: "card.csv", data: try Data(contentsOf: url))
    }

    @Test("Aufladung ist Umbuchung, Cashback ist Cashback, Gebühr eigene Buchung, Euro-Betrag als Original")
    func semantics() async throws {
        let result = try await GenericCSVProvider(fallbackCurrency: .eur).parse(fixture())
        #expect(result.issues.isEmpty)
        #expect(result.transactions.count == 6)

        let receive = result.transactions[0]
        #expect(receive.kind == .transfer)
        #expect(receive.amount == Money(amount: 500, currency: .usd))

        let purchase = result.transactions[1]
        #expect(purchase.kind == .purchase)
        #expect(purchase.amount == Money(amount: Decimal(string: "-46.51")!, currency: .usd))
        #expect(purchase.originalAmount == 40)
        #expect(purchase.originalCurrency == .eur)

        let fee = result.transactions[2]
        #expect(fee.kind == .fee)
        #expect(fee.amount == Money(amount: Decimal(string: "-0.36")!, currency: .usd))
        #expect(fee.rawMerchantName == "Gebühr: SUPERMARKT MUSTER")

        #expect(result.transactions[3].kind == .purchase)
        #expect(result.transactions[4].kind == .cashback)
        #expect(result.transactions[4].amount.amount == Decimal(string: "1.40")!)
        #expect(result.transactions[5].kind == .transfer)
        #expect(result.unknownTypes.isEmpty)
    }

    @Test("Entscheidung des Nutzers hat Vorrang vor dem Wörterbuch")
    func userMeaningWins() async throws {
        let provider = GenericCSVProvider(fallbackCurrency: .eur, typeMeanings: ["RECEIVE": .income])
        let result = try await provider.parse(fixture())
        #expect(result.transactions[0].kind == .income)
    }

    @Test("Vorzeichenbehaftete Datei: Wort und Vorzeichen widersprechen sich, das Vorzeichen gilt")
    func signWinsOverWord() async throws {
        let csv = Data("""
        Datum,Typ,Beschreibung,Betrag
        01.10.2026,Kartenzahlung,Rückgabe Schuhe,"39,90"
        02.10.2026,Kartenzahlung,Bäcker,"-3,20"
        03.10.2026,Rätselart,Irgendwas,"-1,00"
        """.utf8)
        let result = try await GenericCSVProvider(fallbackCurrency: .eur).parse(ImportFile(fileName: "x.csv", data: csv))
        #expect(result.transactions[0].kind == .unknown)
        #expect(result.transactions[0].amount.amount == Decimal(string: "39.90")!)
        #expect(result.transactions[1].kind == .purchase)
        #expect(result.unknownTypes == [UnknownTransactionType(key: "RATSELART", label: "Rätselart", count: 1)])
    }

    @Test("E2E: Aufladungen zählen nicht als Einnahmen, Käufe und Gebühren als Ausgaben")
    func pipelineToAnalytics() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .usd)
        let pipeline = ImportPipeline(
            providers: dependencies.importProviders,
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .usd
        )
        let result = try await pipeline.run(fixture(), into: UUID())
        #expect(result.importedCount == 6)

        let all = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let snapshot = AnalyticsCalculator(baseCurrency: .usd).snapshot(transactions: all, categories: [], calendar: .current)
        #expect(snapshot.totalIncome == 0)
        // 46,51 + 7,00 + 0,36 Gebühr − 1,40 Cashback (netto nach Erstattungen).
        #expect(snapshot.totalSpending == Decimal(string: "52.47")!)
    }
}
