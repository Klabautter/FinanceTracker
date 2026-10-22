import Foundation
import Testing

@testable import FinanceTracker

@Suite("ZipArchiveReader")
struct ZipArchiveReaderTests {
    private final class BundleMarker {}

    private func fixtureData(_ name: String, ext: String) throws -> Data {
        let bundle = Bundle(for: BundleMarker.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw ImportError.parsingFailed(stage: "testSetup", reason: "Fixture \(name).\(ext) nicht gefunden.")
        }
        return try Data(contentsOf: url)
    }

    @Test("Listet Einträge und extrahiert deflatete XML-Dateien")
    func extractsEntries() throws {
        let archive = try ZipArchiveReader(data: fixtureData("fixture_etherfi_cash", ext: "xlsx"))

        #expect(archive.containsEntry(named: "xl/workbook.xml"))
        #expect(archive.containsEntry(named: "xl/worksheets/sheet1.xml"))
        #expect(!archive.entryNames.isEmpty)

        let workbook = try archive.extractEntry("xl/workbook.xml")
        let xml = String(decoding: workbook, as: UTF8.self)
        #expect(xml.contains("sheet"))
    }

    @Test("Kein ZIP wirft Fehler, fehlender Eintrag ebenfalls")
    func errorCases() throws {
        #expect(throws: ZipArchiveError.notAZipArchive) {
            _ = try ZipArchiveReader(data: Data("definitely not a zip".utf8))
        }

        let archive = try ZipArchiveReader(data: fixtureData("fixture_etherfi_cash", ext: "xlsx"))
        #expect(throws: ZipArchiveError.entryNotFound(name: "xl/does-not-exist.xml")) {
            _ = try archive.extractEntry("xl/does-not-exist.xml")
        }
    }
}

@Suite("XLSXConverter")
struct XLSXConverterTests {
    private final class BundleMarker {}

    @Test("Konvertiert ether.fi-xlsx zu CSV mit Header in erster Zeile")
    func convertsEtherFiFixture() throws {
        let bundle = Bundle(for: BundleMarker.self)
        guard let url = bundle.url(forResource: "fixture_etherfi_cash", withExtension: "xlsx") else {
            throw ImportError.parsingFailed(stage: "testSetup", reason: "xlsx-Fixture nicht gefunden.")
        }
        let data = try Data(contentsOf: url)

        #expect(XLSXConverter.isZipArchive(data))

        let csv = try XLSXConverter.csvText(from: data)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines[0].hasPrefix("timestamp,type,description,status,amount,currency"))
        #expect(csv.contains("MCDONALDS 155"))
        #expect(csv.contains("18.3"))
        #expect(csv.contains("PENDING"))
        #expect(csv.contains("0.55"))

        let document = try CSVReader.parse(Data(csv.utf8))
        #expect(document.headers.first == "timestamp")
        #expect(document.recordCount == 6)
    }

    @Test("Spaltengaps werden mit leeren Zellen aufgefüllt")
    func columnGaps() throws {
        let xml = """
        <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1"><v>5</v></c></row>
        </sheetData></worksheet>
        """.data(using: .utf8)!

        let rows = WorksheetRowParser(sharedStrings: ["Header"]).parse(xml)
        #expect(rows.count == 1)
        #expect(rows[0].cells == ["Header", "", "5"])
    }
}
