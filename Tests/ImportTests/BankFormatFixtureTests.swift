import Foundation
import Testing

@testable import FinanceTracker

/// Exporte verschiedener Banken (synthetische Fixtures, keine echten Daten):
/// Vorzeichen, Zahl- und Datumsformate dürfen nie still falsch gelesen werden.
@Suite("Bankformate")
struct BankFormatFixtureTests {
    private final class BundleMarker {}
    private let provider = GenericCSVProvider(fallbackCurrency: .eur)

    private func parse(_ name: String) async throws -> ProviderParseResult {
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "csv"))
        return try await provider.parse(ImportFile(fileName: "\(name).csv", data: Data(contentsOf: url)))
    }

    private func amounts(_ result: ProviderParseResult) -> [Decimal] {
        result.transactions.map(\.amount.amount)
    }

    @Test("ING: Kopfzeilen davor, doppelte Währungsspalte")
    func ing() async throws {
        let result = try await parse("fixture_format_ing")
        #expect(amounts(result) == [Decimal(string: "-23.45")!, 2000])
        #expect(result.transactions.first?.rawMerchantName == "REWE")
        #expect(result.issues.isEmpty)
    }

    @Test("DKB: „2.000“ ist in einer Komma-Datei zweitausend")
    func dkbIntegers() async throws {
        let result = try await parse("fixture_format_dkb_integers")
        #expect(amounts(result) == [Decimal(string: "-12.30")!, 2000])
        #expect(result.transactions.last?.status == .pending)
    }

    @Test("Soll/Haben-Spalte bestimmt das Vorzeichen")
    func sollHaben() async throws {
        let result = try await parse("fixture_format_soll_haben")
        #expect(amounts(result) == [Decimal(string: "-45.10")!, 2500])
    }

    @Test("US-Datum Monat/Tag und Tausender-Komma")
    func usDates() async throws {
        let result = try await parse("fixture_format_us_dates")
        let calendar = Calendar(identifier: .gregorian)
        let days = result.transactions.compactMap(\.bookedAt).map {
            calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: $0)
        }
        #expect(days.map(\.month) == [10, 10])
        #expect(days.map(\.day) == [15, 4])
        #expect(amounts(result) == [Decimal(string: "-54.32")!, 1500])
    }

    @Test("Revolut: ausstehend ohne Abschlussdatum nimmt das Startdatum")
    func revolutPending() async throws {
        let result = try await parse("fixture_format_revolut")
        #expect(result.transactions.count == 2)
        #expect(result.transactions.last?.status == .pending)
        #expect(result.issues.isEmpty)
    }

    @Test("Klammern, nachgestelltes Minus und Plus; ein Datum ist kein Betrag")
    func signNotations() async throws {
        let result = try await parse("fixture_format_sign_notations")
        #expect(amounts(result) == [Decimal(string: "-120.50")!, Decimal(string: "-12.50")!, 5])
        #expect(result.issues.count == 1)
    }
}

@Suite("Betragsparser")
struct CSVMoneyParserStrictTests {
    @Test("Strenge Regeln")
    func strict() {
        #expect(CSVMoneyParser.parse("1.234,56") == Decimal(string: "1234.56"))
        #expect(CSVMoneyParser.parse("1,234.56") == Decimal(string: "1234.56"))
        #expect(CSVMoneyParser.parse("1 234,56 €") == Decimal(string: "1234.56"))
        #expect(CSVMoneyParser.parse("1'234.50") == Decimal(string: "1234.50"))
        #expect(CSVMoneyParser.parse("-12,30 EUR") == Decimal(string: "-12.30"))
        #expect(CSVMoneyParser.parse("45,10 S") == Decimal(string: "-45.10"))
        #expect(CSVMoneyParser.parse("45,10 H") == Decimal(string: "45.10"))
        #expect(CSVMoneyParser.parse("0,125") == Decimal(string: "0.125"))
        #expect(CSVMoneyParser.parse("2.000", decimalSeparator: ",") == 2000)
        #expect(CSVMoneyParser.parse("2.000") == 2)
        #expect(CSVMoneyParser.parse("15.10.2026") == nil)
        #expect(CSVMoneyParser.parse("1.23.45") == nil)
        #expect(CSVMoneyParser.parse("abc") == nil)
        #expect(CSVMoneyParser.parse("12 Stück") == nil)
        #expect(CSVMoneyParser.decimalSeparator(in: ["-12,30", "2.000"]) == ",")
        #expect(CSVMoneyParser.decimalSeparator(in: ["-12.30", "1,500.00"]) == ".")
        #expect(CSVMoneyParser.decimalSeparator(in: ["2.000"]) == nil)
    }
}
