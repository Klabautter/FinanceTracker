import Foundation

enum XLSXConverterError: Error, Equatable {
    case fileTooLarge(size: Int)
    case missingWorksheet
    case malformedXML
}

enum XLSXConverter {
    static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    static func isZipArchive(_ data: Data) -> Bool {
        data.count > 4 && Array(data.prefix(4)) == zipMagic
    }

    static func csvText(from xlsxData: Data) throws -> String {
        guard xlsxData.count <= ImportLimits.maxFileSizeBytes else {
            throw XLSXConverterError.fileTooLarge(size: xlsxData.count)
        }

        let archive = try ZipArchiveReader(data: xlsxData)

        let sharedStrings = loadSharedStrings(in: archive)
        let worksheetPath = try firstWorksheetPath(in: archive)

        var expandedTotal = 0
        for name in ["xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/sharedStrings.xml", worksheetPath] {
            expandedTotal += archive.uncompressedSize(ofEntry: name) ?? 0
        }
        guard expandedTotal <= ImportLimits.maxTotalExpandedBytes else {
            throw ZipArchiveError.totalExpandedSizeExceeded(limit: ImportLimits.maxTotalExpandedBytes)
        }

        let sheetData = try archive.extractEntry(worksheetPath)
        let rows = WorksheetRowParser(sharedStrings: sharedStrings).parse(sheetData)

        guard let headerRowIndex = rows.firstIndex(where: { $0.nonEmptyCellCount >= 3 }) else {
            throw XLSXConverterError.missingWorksheet
        }

        var lines: [String] = []
        for row in rows[headerRowIndex...] {
            lines.append(row.cells.map(Self.quote).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func quote(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private static func loadSharedStrings(in archive: ZipArchiveReader) -> [String] {
        guard archive.containsEntry(named: "xl/sharedStrings.xml"),
              let data = try? archive.extractEntry("xl/sharedStrings.xml") else {
            return []
        }
        return SharedStringsParser().parse(data)
    }

    private static func firstWorksheetPath(in archive: ZipArchiveReader) throws -> String {
        guard let workbookData = try? archive.extractEntry("xl/workbook.xml"),
              let relsData = try? archive.extractEntry("xl/_rels/workbook.xml.rels") else {
            throw XLSXConverterError.missingWorksheet
        }

        let workbook = WorkbookSheetsParser().parse(workbookData)
        guard let relationshipID = workbook.firstSheetRelationshipID else {
            throw XLSXConverterError.missingWorksheet
        }

        let relationships = WorkbookRelationshipsParser().parse(relsData)
        guard let target = relationships[relationshipID] else {
            throw XLSXConverterError.missingWorksheet
        }

        if target.hasPrefix("/") {
            return String(target.dropFirst())
        }
        return "xl/" + target
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var currentItem = ""
    private var isInsideTextElement = false
    private var textBuffer = ""

    func parse(_ data: Data) -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return strings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "si":
            currentItem.removeAll(keepingCapacity: true)
        case "t":
            isInsideTextElement = true
            textBuffer.removeAll(keepingCapacity: true)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInsideTextElement {
            textBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "t":
            currentItem += textBuffer
            isInsideTextElement = false
        case "si":
            strings.append(currentItem)
        default:
            break
        }
    }
}

private final class WorkbookSheetsParser: NSObject, XMLParserDelegate {
    private(set) var firstSheetRelationshipID: String?

    func parse(_ data: Data) -> (firstSheetRelationshipID: String?, sheetNames: [String]) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return (firstSheetRelationshipID, [])
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "sheet", firstSheetRelationshipID == nil {
            firstSheetRelationshipID = attributeDict["r:id"] ?? attributeDict["id"]
        }
    }
}

private final class WorkbookRelationshipsParser: NSObject, XMLParserDelegate {
    private var relationships: [String: String] = [:]

    func parse(_ data: Data) -> [String: String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return relationships
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "Relationship",
           let id = attributeDict["Id"],
           let target = attributeDict["Target"] {
            relationships[id] = target
        }
    }
}

final class WorksheetRowParser: NSObject, XMLParserDelegate {
    struct ParsedRow {
        let cells: [String]
        var nonEmptyCellCount: Int { cells.filter { !$0.isEmpty }.count }
    }

    private let sharedStrings: [String]
    private(set) var rows: [ParsedRow] = []

    private var rowCells: [Int: String] = [:]
    private var currentColumnIndex = 0
    private var currentType = ""
    private var valueBuffer = ""
    private var isInValueElement = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parse(_ data: Data) -> [ParsedRow] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return rows
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "row":
            rowCells.removeAll(keepingCapacity: true)
        case "c":
            currentColumnIndex = Self.columnIndex(forReference: attributeDict["r"] ?? "")
            currentType = attributeDict["t"] ?? ""
            valueBuffer.removeAll(keepingCapacity: true)
        case "v":
            isInValueElement = true
            valueBuffer.removeAll(keepingCapacity: true)
        case "t":
            isInValueElement = true
            valueBuffer.removeAll(keepingCapacity: true)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInValueElement {
            valueBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "v":
            isInValueElement = false
        case "t":
            isInValueElement = false
        case "c":
            finalizeCell()
        case "row":
            finalizeRow()
        default:
            break
        }
    }

    private func finalizeCell() {
        let resolved: String
        switch currentType {
        case "s":
            let index = Int(valueBuffer.trimmingCharacters(in: .whitespaces)) ?? -1
            resolved = index >= 0 && index < sharedStrings.count ? sharedStrings[index] : ""
        case "inlineStr":
            resolved = valueBuffer
        default:
            resolved = valueBuffer
        }
        rowCells[currentColumnIndex] = resolved
    }

    private func finalizeRow() {
        guard !rowCells.isEmpty else { return }
        let maxIndex = rowCells.keys.max() ?? 0
        var cells: [String] = []
        cells.reserveCapacity(maxIndex + 1)
        for index in 0...maxIndex {
            cells.append(rowCells[index] ?? "")
        }
        rows.append(ParsedRow(cells: cells))
    }

    static func columnIndex(forReference reference: String) -> Int {
        var index = 0
        for scalar in reference.unicodeScalars where scalar.value >= 65 && scalar.value <= 90 {
            index = index * 26 + Int(scalar.value - 64)
        }
        return max(0, index - 1)
    }
}
