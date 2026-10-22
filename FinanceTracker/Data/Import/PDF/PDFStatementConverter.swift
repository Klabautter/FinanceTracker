import Foundation
import PDFKit

enum PDFStatementError: Error, Equatable {
    case unreadable
    case noText
    case noTable
}

/// Liest die Umsatztabelle eines PDF-Kontoauszugs und gibt sie als CSV-Text
/// weiter: danach läuft derselbe Import wie für jede andere Tabelle.
///
/// Ein PDF kennt keine Tabellen, nur Wörter an Positionen. Die Spalten
/// ergeben sich aus der Überschriftenzeile (dieselbe Erkennung wie beim
/// CSV-Import), die Zeilen aus den Betragszeilen: Alles, was dicht um einen
/// Betrag steht, gehört zu dieser Buchung, so bleiben mehrzeilige
/// Beschreibungen und umbrochene Datumsangaben zusammen.
enum PDFStatementConverter {
    static let magic: [UInt8] = [0x25, 0x50, 0x44, 0x46, 0x2D] // "%PDF-"

    static func isPDF(_ data: Data) -> Bool {
        data.count > magic.count && Array(data.prefix(magic.count)) == magic
    }

    static func csvText(from data: Data) throws -> String {
        guard let document = PDFDocument(data: data), !document.isLocked else {
            throw PDFStatementError.unreadable
        }
        var pages: [[Word]] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            pages.append(words(on: page))
        }
        guard pages.contains(where: { !$0.isEmpty }) else { throw PDFStatementError.noText }
        return try csvText(fromPages: pages)
    }

    // MARK: - Wörter mit Position

    struct Word: Equatable {
        var text: String
        var minX: Double
        var maxX: Double
        /// Vertikale Mitte, von der Seitenoberkante gemessen.
        var midY: Double
        var height: Double
    }

    private static func words(on page: PDFPage) -> [Word] {
        guard let string = page.string else { return [] }
        let text = string as NSString
        let pageHeight = Double(page.bounds(for: .mediaBox).height)
        var result: [Word] = []

        // Position je Wort über eine Auswahl: Nur sie verwendet dieselbe
        // Zeichenzählung wie `page.string`.
        var location = 0
        let separators = CharacterSet.whitespacesAndNewlines
        while location < text.length {
            let rest = NSRange(location: location, length: text.length - location)
            let start = text.rangeOfCharacter(from: separators.inverted, options: [], range: rest)
            guard start.location != NSNotFound else { break }
            let tail = NSRange(location: start.location, length: text.length - start.location)
            let end = text.rangeOfCharacter(from: separators, options: [], range: tail)
            let wordEnd = end.location == NSNotFound ? text.length : end.location
            let range = NSRange(location: start.location, length: wordEnd - start.location)
            location = wordEnd

            guard let bounds = page.selection(for: range)?.bounds(for: page),
                  !bounds.isNull, bounds.width > 0, bounds.height > 0 else { continue }
            result.append(Word(
                text: text.substring(with: range),
                minX: Double(bounds.minX),
                maxX: Double(bounds.maxX),
                midY: pageHeight - Double(bounds.midY),
                height: Double(bounds.height)
            ))
        }
        return result
    }

    // MARK: - Tabelle

    private struct Column {
        let name: String
        let minX: Double
        let maxX: Double
    }

    private struct Header {
        let columns: [Column]
        let y: Double
        let mapping: GenericCSVMapping
        var names: [String] { columns.map(\.name) }
    }

    /// Kern ohne PDFKit: aus positionierten Wörtern je Seite wird CSV-Text.
    static func csvText(fromPages pages: [[Word]]) throws -> String {
        var table: Header?
        var rows: [[String]] = []
        var anchorGaps: [Double] = []
        var pending: [(words: [Word], anchors: [Double], header: Header)] = []

        for pageWords in pages {
            let pageLines = lines(of: pageWords)
            guard let header = header(in: pageLines, matching: table) else { continue }
            if table == nil { table = header }

            let end = tableEnd(in: pageLines, below: header)
            let body = pageWords.filter { $0.midY > header.y + lineTolerance(pageWords) && $0.midY < end }
            let anchors = anchorLines(in: body, header: header)
            anchorGaps.append(contentsOf: zip(anchors.dropFirst(), anchors).map { $0 - $1 })
            pending.append((body, anchors, header))
        }

        guard let table else { throw PDFStatementError.noTable }

        // Eine Buchung reicht höchstens einen halben üblichen Zeilenabstand
        // nach oben und unten: Fußzeilen und Zwischentitel bleiben draußen.
        let sortedGaps = anchorGaps.sorted()
        let typicalGap = sortedGaps.isEmpty ? nil : sortedGaps[sortedGaps.count / 2]

        for page in pending {
            for (index, anchor) in page.anchors.enumerated() {
                var lower = index > 0 ? (page.anchors[index - 1] + anchor) / 2 : -Double.infinity
                var upper = index + 1 < page.anchors.count ? (anchor + page.anchors[index + 1]) / 2 : Double.infinity
                let reach = (typicalGap ?? 3 * medianHeight(page.words)) / 2 + 1
                lower = max(lower, anchor - reach)
                upper = min(upper, anchor + reach)

                var cellWords = [[Word]](repeating: [], count: table.columns.count)
                // Wörter bleiben in der Lesereihenfolge des Dokuments, bei
                // eng gesetzten Folgezeilen ist sie verlässlicher als die
                // Geometrie.
                for word in page.words where word.midY >= lower && word.midY < upper {
                    guard let column = columnIndex(for: word, in: page.header.columns) else { continue }
                    cellWords[column].append(word)
                }
                // Ausnahme Datum: „29 Apr." über „2025" steht klar getrennt
                // untereinander und wird von oben nach unten gelesen.
                if let dateIndex = table.names.firstIndex(of: table.mapping.dateColumn) {
                    cellWords[dateIndex] = lines(of: cellWords[dateIndex]).flatMap { $0 }
                }
                let cells = cellWords.map { withoutNullArtifact($0.map(\.text).joined(separator: " ")) }
                rows.append(cells)
            }
        }

        guard !rows.isEmpty else { throw PDFStatementError.noTable }
        return ([table.names] + rows)
            .map { $0.map(csvField).joined(separator: ";") }
            .joined(separator: "\n")
    }

    /// Manche Auszüge hängen ein leeres Feld als Wort „null" direkt an den
    /// Text („APOTHEKEnull"). Das gehört nicht zum Händlernamen.
    static func withoutNullArtifact(_ text: String) -> String {
        guard text.count > 4, text.hasSuffix("null"),
              let before = text.dropLast(4).last, !before.isWhitespace else { return text }
        return String(text.dropLast(4))
    }

    private static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Zeilen und Überschrift

    private static func medianHeight(_ words: [Word]) -> Double {
        let heights = words.map(\.height).sorted()
        return heights.isEmpty ? 8 : heights[heights.count / 2]
    }

    private static func lineTolerance(_ words: [Word]) -> Double {
        // Eng genug, dass dicht gesetzte Folgezeilen getrennt bleiben.
        max(1.5, 0.2 * medianHeight(words))
    }

    private static func lines(of words: [Word]) -> [[Word]] {
        let tolerance = lineTolerance(words)
        var result: [[Word]] = []
        for word in words.sorted(by: { $0.midY < $1.midY }) {
            if let first = result.last?.first, word.midY - first.midY <= tolerance {
                result[result.count - 1].append(word)
            } else {
                result.append([word])
            }
        }
        return result.map { $0.sorted { $0.minX < $1.minX } }
    }

    /// Die Überschriftenzeile der Umsatztabelle. Auf Folgeseiten muss sie
    /// dieselben Spalten haben: eine andere Tabelle im selben Dokument
    /// (z. B. eine Depotübersicht) wird nicht mitgelesen.
    private static func header(in lines: [[Word]], matching table: Header?) -> Header? {
        for line in lines where line.count >= 2 {
            for cells in [merged(line), line] {
                let names = cells.map(\.text)
                if let table {
                    guard names == table.names else { continue }
                } else if Set(names).count != names.count {
                    continue
                }
                guard let mapping = GenericCSVMapping.detect(in: CSVDocument(headers: names, records: [])) else {
                    continue
                }
                return Header(
                    columns: cells.map { Column(name: $0.text, minX: $0.minX, maxX: $0.maxX) },
                    y: line[0].midY,
                    mapping: mapping
                )
            }
        }
        return nil
    }

    /// Fasst mehrwortige Überschriften („Booking date") zu einer Zelle zusammen.
    private static func merged(_ line: [Word]) -> [Word] {
        var result: [Word] = []
        for word in line {
            if var last = result.last, word.minX - last.maxX < 0.45 * word.height {
                last.text += " " + word.text
                last.maxX = word.maxX
                result[result.count - 1] = last
            } else {
                result.append(word)
            }
        }
        return result
    }

    /// Die Tabelle endet, wo unter ihr erneut eine Spaltenüberschrift an
    /// ihrer Position steht: dort beginnt ein anderer Abschnitt.
    private static func tableEnd(in lines: [[Word]], below header: Header) -> Double {
        for line in lines where line[0].midY > header.y + 1 {
            let repeatsHeader = line.contains { word in
                header.columns.contains { $0.name == word.text && overlap(word, $0) > 1 }
            }
            if repeatsHeader { return line[0].midY - 1 }
        }
        return .infinity
    }

    /// Zeilen, in denen ein Buchungsbetrag steht: jede ist eine Buchung.
    private static func anchorLines(in body: [Word], header: Header) -> [Double] {
        let amountNames = [header.mapping.amountColumn, header.mapping.debitColumn, header.mapping.creditColumn]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let amountColumns = Set(header.columns.indices.filter { amountNames.contains(header.columns[$0].name) })
        return lines(of: body)
            .filter { line in
                line.contains { word in
                    guard let column = columnIndex(for: word, in: header.columns) else { return false }
                    return amountColumns.contains(column) && looksLikeAmount(word.text)
                }
            }
            .map { $0[0].midY }
    }

    /// Ein Geldbetrag mit zwei Nachkommastellen („1.234,56", „-12.50", „8,04€").
    /// Seitenzahlen, Registernummern und Stückzahlen in der Fußzeile sind
    /// keine Buchungen.
    static func looksLikeAmount(_ text: String) -> Bool {
        let digitsAndMarks = text.filter { $0.isNumber || ".,'".contains($0) }
        guard digitsAndMarks.count >= 4,
              text.allSatisfy({ $0.isNumber || ".,'+-−€$£".contains($0) }) else { return false }
        let decimals = digitsAndMarks.suffix(3)
        return (decimals.first == "," || decimals.first == ".") && decimals.dropFirst().allSatisfy(\.isNumber)
    }

    private static func overlap(_ word: Word, _ column: Column) -> Double {
        min(word.maxX, column.maxX) - max(word.minX, column.minX)
    }

    /// Spalte eines Wortes: die Überschrift, unter der es steht (auch
    /// rechtsbündige Zahlen); sonst die nächste Überschrift links davon
    /// (linksbündiger Text, der breiter ist als seine Überschrift).
    private static func columnIndex(for word: Word, in columns: [Column]) -> Int? {
        let overlapping = columns.indices
            .map { ($0, overlap(word, columns[$0])) }
            .filter { $0.1 > 1 }
        if let best = overlapping.max(by: { $0.1 < $1.1 }) {
            return best.0
        }
        return columns.indices.last { columns[$0].minX <= word.minX + 2 }
    }
}
