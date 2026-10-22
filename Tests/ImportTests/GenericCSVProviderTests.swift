import Foundation
import Testing

@testable import FinanceTracker

@Suite("GenericCSVProvider")
struct GenericCSVProviderTests {
    private final class BundleMarker {}

    private func fixtureData(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleMarker.self)
        guard let url = bundle.url(forResource: name, withExtension: "csv") else {
            throw ImportError.parsingFailed(stage: "testSetup", reason: "Fixture \(name).csv nicht gefunden.")
        }
        return try Data(contentsOf: url)
    }

    private var provider: GenericCSVProvider { GenericCSVProvider(fallbackCurrency: .eur) }

    @Test("Erkennt deutsches Semikolon-Format und mappt alle Spalten")
    func parsesGermanFixture() async throws {
        let file = ImportFile(fileName: "bank.csv", data: try fixtureData("fixture_generic_bank_de"))
        let parsed = try await provider.parse(file)
        let transactions = parsed.transactions

        #expect(transactions.count == 3)

        let rent = transactions[0]
        #expect(rent.amount.amount == Decimal(string: "-985.00")!)
        #expect(rent.amount.currency == .eur)
        #expect(rent.merchantDisplayName == "Vermieter Musterstr.")
        #expect(rent.rawDescription == "Miete August inkl. NK")

        let groceries = transactions[1]
        #expect(groceries.amount.amount == Decimal(string: "-43.27")!)
        #expect(groceries.merchantDisplayName == "REWE")

        let salary = transactions[2]
        #expect(salary.amount.amount == 2850)
    }

    @Test("canHandle ist true für erkennbares Format, false ohne Betragsspalte")
    func canHandleDetection() async throws {
        let good = ImportFile(fileName: nil, data: try fixtureData("fixture_generic_bank_de"))
        #expect(try await provider.canHandle(good) == true)

        let bad = ImportFile(fileName: nil, data: Data("Name;Stadt\nAnna;Wien\n".utf8))
        #expect(try await provider.canHandle(bad) == false)
    }

    @Test("Ohne Datums-/Betragsspalte wirft parse missingColumns")
    func parseThrowsOnMissingColumns() async throws {
        let bad = ImportFile(fileName: nil, data: Data("Name;Betrag\nX;1,00\n".utf8))

        await #expect(throws: ImportError.self) {
            try await provider.parse(bad)
        }
    }

    // MARK: - Beliebige Bank- und Brokerexporte

    @Test("Kopfzeilen vor der Tabelle, Windows-1252 und getrennte Soll-/Haben-Spalten")
    func parsesPreambleLatin1SplitAmounts() async throws {
        let file = ImportFile(fileName: "umsaetze.csv", data: try fixtureData("fixture_generic_preamble_latin1"))
        #expect(try await provider.canHandle(file))

        let result = try await provider.parse(file)
        #expect(result.totalRows == 4)
        #expect(result.transactions.count == 3)

        let rent = result.transactions[0]
        #expect(rent.amount == Money(amount: Decimal(string: "-985.00")!, currency: .eur))
        #expect(rent.rawMerchantName == "Vermieter Müller")
        #expect(rent.rawDescription == "Miete September")

        #expect(result.transactions[1].rawMerchantName == "Bäckerei Schön")
        #expect(result.transactions[2].amount == Money(amount: 2850, currency: .eur))

        // Soll und Haben gleichzeitig gefüllt: gezählter Zeilenfehler, kein Raten.
        #expect(result.issues.count == 1)
        #expect(result.issues[0].rowIndex == 4)
    }

    @Test("Brokerexport: Status, Referenz und Wertpapiergeschäfte ohne bankspezifischen Parser")
    func parsesBrokerExport() async throws {
        let file = ImportFile(fileName: "transactions.csv", data: try fixtureData("fixture_generic_broker"))
        #expect(try await provider.canHandle(file))

        let result = try await provider.parse(file)
        #expect(result.totalRows == 6)
        #expect(result.transactions.count == 5)

        let byReference = Dictionary(uniqueKeysWithValues: result.transactions.map { ($0.externalID ?? "", $0) })
        // Käufe, Verkäufe und Sparpläne zählen als Ausgabe/Einnahme in „Geldanlage".
        for reference in ["REF-1001", "REF-1002", "REF-1004"] {
            #expect(byReference[reference]?.kind == .unknown)
            #expect(byReference[reference]?.suggestedCategoryID == Category.investments.id)
        }
        #expect(byReference["REF-1004"]?.status == .cancelled)
        // Zinsen und Kartenzahlungen bekommen keinen Kategorievorschlag.
        #expect(byReference["REF-1003"]?.suggestedCategoryID == nil)
        #expect(byReference["REF-1003"]?.status == .booked)
        #expect(byReference["REF-1005"]?.suggestedCategoryID == nil)
        #expect(byReference["REF-1005"]?.amount == Money(amount: Decimal(string: "-23.90")!, currency: .eur))

        // Unbekannter Status wird nicht als „gebucht" geraten.
        #expect(result.issues.map(\.rowIndex) == [6])
    }

    @Test("Nebenbeträge und fremde ID-Spalten werden nicht als Betrag bzw. Buchungs-ID erkannt")
    func ignoresMisleadingColumns() throws {
        let document = CSVDocument(
            headers: ["Value date", "Originalbetrag", "Gläubiger-ID", "Kontoname", "Betrag (EUR)", "Booking date"],
            records: []
        )
        let mapping = try #require(GenericCSVMapping.detect(in: document))
        #expect(mapping.amountColumn == "Betrag (EUR)")
        #expect(mapping.dateColumn == "Booking date")
        #expect(mapping.externalIDColumn == nil)
        #expect(mapping.merchantColumn == nil)
    }
}
