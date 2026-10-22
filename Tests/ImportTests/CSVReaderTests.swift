import Foundation
import Testing

@testable import FinanceTracker

@Suite("CSVReader")
struct CSVReaderTests {
    private final class BundleMarker {}

    private func fixtureData(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleMarker.self)
        guard let url = bundle.url(forResource: name, withExtension: "csv") else {
            throw ImportError.parsingFailed(stage: "testSetup", reason: "Fixture \(name).csv nicht im Test-Bundle gefunden.")
        }
        return try Data(contentsOf: url)
    }

    @Test("Komma-Datei mit Komma im quoted Feld und escaped Quotes")
    func commaDelimited() throws {
        let document = try CSVReader.parse(fixtureData("fixture_comma_bank"))

        #expect(document.headers == ["Datum", "Beschreibung", "Betrag", "Waehrung"])
        #expect(document.recordCount == 3)

        let dictionaries = document.recordDictionaries()
        #expect(dictionaries[0]["Beschreibung"] == "REWE SAGT DANKE, 832741 MUENCHEN")
        #expect(dictionaries[0]["Betrag"] == "-43.27")
        #expect(dictionaries[2]["Beschreibung"] == "Shell \"Vollservice\" 123")
    }

    @Test("Semikolon wird automatisch erkannt, BOM wird ignoriert")
    func semicolonWithBOM() throws {
        var data = try fixtureData("fixture_semicolon_german")
        data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)

        let document = try CSVReader.parse(data)

        #expect(document.headers.first == "Buchungstag")
        #expect(document.recordCount == 2)
        let first = document.recordDictionaries()[0]
        #expect(first["Verwendungszweck"] == "Miete August; inkl. NK")
    }

    @Test("Zeilenumbruch innerhalb quoted Felds erzeugt keinen neuen Datensatz")
    func multilineField() throws {
        let document = try CSVReader.parse(fixtureData("fixture_multiline"))

        #expect(document.recordCount == 2)
        let memo = document.recordDictionaries()[0]["Memo"]
        #expect(memo?.contains("\n") == true)
        #expect(memo?.contains("still same field") == true)
    }

    @Test("CRLF-Zeilenenden werden behandelt, leere Zeilen übersprungen")
    func crlfAndBlankLines() throws {
        let content = "A,B\r\n1,2\r\n\r\n3,4\r\n"
        let document = try CSVReader.parse(content)

        #expect(document.recordCount == 2)
        #expect(document.records[0] == ["1", "2"])
        #expect(document.records[1] == ["3", "4"])
    }

    @Test("Letzte Zeile ohne Zeilenende wird trotzdem gelesen")
    func missingTrailingNewline() throws {
        let document = try CSVReader.parse("X,Y\nfoo,bar")

        #expect(document.recordCount == 1)
        #expect(document.records[0] == ["foo", "bar"])
    }

    @Test("Leere Eingabe wirft Fehler")
    func emptyInputThrows() {
        #expect(throws: CSVReadError.emptyInput) {
            try CSVReader.parse("")
        }
    }

    @Test("value() findet Spalten case-insensitive über den Header")
    func valueLookup() throws {
        let document = try CSVReader.parse("Merchant,AMOUNT\nREWE,-43.27")

        #expect(document.value("merchant", in: document.records[0]) == "REWE")
        #expect(document.value("amount", in: document.records[0]) == "-43.27")
        #expect(document.value("fehlt", in: document.records[0]) == nil)
    }
}

@Suite("CSVDetection")
struct CSVDetectionTests {
    @Test("Delimiter-Erkennung wählt häufigstes Zeichen der ersten Zeile")
    func delimiterDetection() {
        #expect(CSVDetection.detectDelimiter(in: "a,b,c\n1;2;3") == ",")
        #expect(CSVDetection.detectDelimiter(in: "a;b;c\n1,2,3") == ";")
        #expect(CSVDetection.detectDelimiter(in: "a\tb\tc") == "\t")
        #expect(CSVDetection.detectDelimiter(in: "onlyonecolumn") == ",")
    }

    @Test("Header-Matching ist case-insensitive und trimmt Whitespace")
    func headerMatching() {
        let headers = [" Buchungstag ", "BETRAG"]
        #expect(CSVDetection.containsAll(headers, required: ["buchungstag", "betrag"]))
        #expect(!CSVDetection.containsAll(headers, required: ["buchungstag", "waehrung"]))
    }
}
