import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import FinanceTracker

/// PDF-Kontoauszüge: Das Test-PDF wird hier gezeichnet (künstliche Daten),
/// damit kein echter Auszug im Repository liegt.
@Suite("PDFStatementImport")
struct PDFStatementImportTests {
    private struct Text {
        let string: String
        let x: CGFloat
        /// Abstand von der Seitenoberkante.
        let top: CGFloat
    }

    private static let pageSize = CGSize(width: 595, height: 842)
    private static let columns: (date: CGFloat, type: CGFloat, text: CGFloat, incoming: CGFloat, outgoing: CGFloat, balance: CGFloat) =
        (74, 110, 190, 350, 425, 510)

    private static func header(top: CGFloat) -> [Text] {
        [
            Text(string: "DATUM", x: columns.date, top: top),
            Text(string: "TYP", x: columns.type, top: top),
            Text(string: "BESCHREIBUNG", x: columns.text, top: top),
            Text(string: "ZAHLUNGSEINGANG", x: columns.incoming, top: top),
            Text(string: "ZAHLUNGSAUSGANG", x: columns.outgoing, top: top),
            Text(string: "SALDO", x: columns.balance, top: top)
        ]
    }

    /// Eine Buchung im Stil eines Auszugs: Datum über zwei Zeilen, die
    /// Beschreibung ggf. über drei, Betrag und Saldo auf der mittleren.
    private static func row(
        top: CGFloat,
        day: String,
        year: String,
        type: String,
        description: [String],
        incoming: String? = nil,
        outgoing: String? = nil,
        balance: String
    ) -> [Text] {
        var texts = [
            Text(string: day, x: columns.date, top: top - 5),
            Text(string: year, x: columns.date, top: top + 5),
            Text(string: type, x: columns.type, top: top),
            Text(string: balance, x: columns.balance, top: top)
        ]
        let firstLine = top - CGFloat(description.count - 1) * 5
        for (index, line) in description.enumerated() {
            texts.append(Text(string: line, x: columns.text, top: firstLine + CGFloat(index) * 10))
        }
        if let incoming { texts.append(Text(string: incoming, x: columns.incoming, top: top)) }
        if let outgoing { texts.append(Text(string: outgoing, x: columns.outgoing, top: top)) }
        return texts
    }

    private static func footer(page: Int) -> [Text] {
        [
            Text(string: "Beispielbank GmbH   HRB 244347 B   Umsatzsteuer-ID DE123456789", x: 74, top: 790),
            Text(string: "Seite \(page) von 2", x: 480, top: 805)
        ]
    }

    private static func makePDF(pages: [[Text]]) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 6, nil)
        for page in pages {
            context.beginPDFPage(nil)
            for text in page {
                let attributed = NSAttributedString(
                    string: text.string,
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
                )
                context.textPosition = CGPoint(x: text.x, y: pageSize.height - text.top)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static var statement: Data {
        let pageOne: [Text] =
            [Text(string: "KONTOÜBERSICHT   Anfangssaldo 1.000,00 €", x: 74, top: 120)]
            + header(top: 200)
            + row(top: 230, day: "01 Juli", year: "2026", type: "Zinsen", description: ["Zinszahlung"], incoming: "8,04 €", balance: "1.008,04 €")
            + row(top: 270, day: "02 Juli", year: "2026", type: "Kartentransaktion", description: ["SUPERMARKT MUSTER"], outgoing: "15,73 €", balance: "992,31 €")
            + row(
                top: 320, day: "16 Sept.", year: "2026", type: "Handel",
                description: ["Savings plan execution XX0000000001", "Beispiel World ETF,", "quantity: 2.844788"],
                outgoing: "50,00 €", balance: "942,31 €"
            )
            + footer(page: 1)
        let pageTwo: [Text] =
            header(top: 120)
            + row(top: 150, day: "10 Okt.", year: "2026", type: "Kartentransaktion", description: ["RESTAURANT BEISPIEL"], outgoing: "19,80 €", balance: "922,51 €")
            // Ein anderer Abschnitt unter der Umsatztabelle gehört nicht dazu.
            + [
                Text(string: "BARMITTELÜBERSICHT", x: 74, top: 230),
                Text(string: "TREUHANDKONTEN", x: 74, top: 260),
                Text(string: "SALDO", x: columns.balance, top: 260),
                Text(string: "Musterbank", x: 74, top: 280),
                Text(string: "4.000,00 €", x: columns.balance, top: 280)
            ]
            + footer(page: 2)
        return makePDF(pages: [pageOne, pageTwo])
    }

    @Test("Umsatztabelle eines PDF-Auszugs wird über mehrere Seiten gelesen, Fußzeilen und Nachbarabschnitte nicht")
    func readsStatementTable() async throws {
        let file = ImportFile(fileName: "auszug.pdf", data: Self.statement)
        #expect(PDFStatementConverter.isPDF(file.data))

        let normalized = try ImportPipeline.withNormalizedSpreadsheet(file)
        let provider = GenericCSVProvider(fallbackCurrency: .eur)
        #expect(try await provider.canHandle(normalized))

        let result = try await provider.parse(normalized)
        #expect(result.issues.isEmpty)
        #expect(result.totalRows == 4)
        #expect(result.transactions.map(\.amount.amount) == [
            Decimal(string: "8.04")!, Decimal(string: "-15.73")!, -50, Decimal(string: "-19.80")!
        ])

        let calendar = Calendar(identifier: .gregorian)
        let dates = result.transactions.compactMap(\.bookedAt).map {
            calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: $0)
        }
        #expect(dates.map(\.day) == [1, 2, 16, 10])
        #expect(dates.map(\.month) == [7, 7, 9, 10])
        #expect(dates.allSatisfy { $0.year == 2026 })

        #expect(result.transactions[1].rawDescription == "SUPERMARKT MUSTER")
        // Mehrzeilige Beschreibung bleibt in Lesereihenfolge zusammen.
        #expect(result.transactions[2].rawDescription
            == "Savings plan execution XX0000000001 Beispiel World ETF, quantity: 2.844788")
        #expect(result.transactions[2].suggestedCategoryID == Category.investments.id)
        #expect(result.transactions[3].suggestedCategoryID == nil)
    }

    @Test("PDF ohne Umsatztabelle wird mit verständlicher Meldung abgelehnt")
    func rejectsPDFWithoutTable() {
        let data = Self.makePDF(pages: [[Text(string: "Nur ein Brief ohne Tabelle", x: 74, top: 100)]])
        #expect(throws: ImportError.unsupportedFormat(
            reason: "Im PDF wurde keine Umsatztabelle mit Datum und Betrag gefunden."
        )) {
            try ImportPipeline.withNormalizedSpreadsheet(ImportFile(fileName: "brief.pdf", data: data))
        }
    }

    @Test("Nur Geldbeträge verankern eine Buchungszeile")
    func amountShape() {
        #expect(PDFStatementConverter.looksLikeAmount("1.234,56"))
        #expect(PDFStatementConverter.looksLikeAmount("8,04€"))
        #expect(PDFStatementConverter.looksLikeAmount("-12.50"))
        #expect(!PDFStatementConverter.looksLikeAmount("244347"))
        #expect(!PDFStatementConverter.looksLikeAmount("DE307510626"))
        #expect(!PDFStatementConverter.looksLikeAmount("1"))
    }

    @Test("Datumsangaben mit Monatsnamen")
    func monthNameDates() {
        #expect(CSVDateParser.parse("01 Juli 2024") == CSVDateParser.parse("01.07.2024"))
        #expect(CSVDateParser.parse("12. Okt. 2026") == CSVDateParser.parse("12.10.2026"))
        #expect(CSVDateParser.parse("16 Sept. 2026") == CSVDateParser.parse("16.09.2026"))
        #expect(CSVDateParser.parse("3 März 2025") == CSVDateParser.parse("03.03.2025"))
        #expect(CSVDateParser.parse("31 Feb. 2026") == nil)
    }

    @Test("Zwei gleiche Buchungen am selben Tag bleiben über den Kontostand unterscheidbar")
    func balanceKeepsIdenticalBookingsApart() async throws {
        let csv = """
        Datum;Beschreibung;Betrag;Saldo
        02.07.2026;BAECKEREI MUSTER;-3,50;996,50
        02.07.2026;BAECKEREI MUSTER;-3,50;993,00
        """
        let result = try await GenericCSVProvider(fallbackCurrency: .eur)
            .parse(ImportFile(fileName: "auszug.csv", data: Data(csv.utf8)))
        #expect(result.transactions.map(\.balanceAfter) == [Decimal(string: "996.50")!, 993])

        let accountID = UUID()
        let fingerprints = Set(result.transactions.map {
            TransactionFingerprinter.fingerprint(
                source: .genericCSV,
                accountID: accountID,
                bookingDate: $0.bookedAt,
                amount: $0.amount,
                merchantOrDescription: $0.rawDescription,
                balanceAfter: $0.balanceAfter
            )
        })
        #expect(fingerprints.count == 2)

        // Ohne Kontostand bleibt der bisherige Fingerprint unverändert.
        let first = result.transactions[0]
        #expect(
            TransactionFingerprinter.fingerprint(
                source: .genericCSV, accountID: accountID, bookingDate: first.bookedAt,
                amount: first.amount, merchantOrDescription: first.rawDescription
            ) == TransactionFingerprinter.fingerprint(
                source: .genericCSV, accountID: accountID, bookingDate: first.bookedAt,
                amount: first.amount, merchantOrDescription: first.rawDescription, balanceAfter: nil
            )
        )
    }
}
