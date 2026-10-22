import Foundation

struct CSVDocument: Equatable, Sendable {
    let headers: [String]
    let records: [[String]]

    var recordCount: Int { records.count }

    func recordDictionaries() -> [[String: String]] {
        records.map { record in
            var dictionary: [String: String] = [:]
            for (index, header) in headers.enumerated() where index < record.count {
                dictionary[header] = record[index]
            }
            return dictionary
        }
    }

    func value(_ header: String, in record: [String]) -> String? {
        guard let index = normalizedHeaderIndex(for: header) else { return nil }
        return index < record.count ? record[index] : nil
    }

    private func normalizedHeaderIndex(for header: String) -> Int? {
        let needle = header.trimmingCharacters(in: .whitespaces).lowercased()
        for (index, existing) in headers.enumerated() {
            if existing.trimmingCharacters(in: .whitespaces).lowercased() == needle {
                return index
            }
        }
        return nil
    }
}

enum CSVReadError: Error, Equatable {
    case emptyInput
    case noHeaderRow
}

enum CSVReader {
    static func parse(_ data: Data) throws -> CSVDocument {
        try parse(text(from: data))
    }

    /// Dekodiert die Datei als UTF-8; ältere Bankexporte (Windows-1252 /
    /// ISO-8859-1) sind kein gültiges UTF-8 und werden dann in ihrer
    /// Kodierung gelesen, damit Umlaute erhalten bleiben.
    static func text(from data: Data) -> String {
        var content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }
        return content
    }

    static func parse(_ content: String) throws -> CSVDocument {
        let records = try parseRows(content)
        guard let headerRow = records.first, !headerRow.isEmpty else {
            throw CSVReadError.noHeaderRow
        }

        return CSVDocument(
            headers: headerRow.map { $0.trimmingCharacters(in: .whitespaces) },
            records: Array(records.dropFirst())
        )
    }

    /// Alle Zeilen der Datei ohne Annahme, welche davon die Überschrift ist.
    static func parseRows(_ data: Data) throws -> [[String]] {
        try parseRows(text(from: data))
    }

    static func parseRows(_ content: String) throws -> [[String]] {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CSVReadError.emptyInput
        }

        let delimiter = CSVDetection.detectDelimiter(in: content)

        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var index = content.startIndex

        func endField() {
            fields.append(field)
            field.removeAll(keepingCapacity: true)
        }

        func endRecord() {
            endField()
            let isBlankLine = fields.count == 1 && fields[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !isBlankLine {
                records.append(fields)
            }
            fields.removeAll(keepingCapacity: true)
        }

        while index < content.endIndex {
            let char = content[index]

            if inQuotes {
                if char == "\"" {
                    let next = content.index(after: index)
                    if next < content.endIndex && content[next] == "\"" {
                        field.append("\"")
                        index = content.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                        index = next
                        continue
                    }
                } else {
                    field.append(char)
                    index = content.index(after: index)
                    continue
                }
            }

            switch char {
            case "\"":
                inQuotes = true
                index = content.index(after: index)

            case delimiter:
                endField()
                index = content.index(after: index)

            case "\r\n":
                endRecord()
                index = content.index(after: index)

            case "\r":
                endRecord()
                index = content.index(after: index)

            case "\n":
                endRecord()
                index = content.index(after: index)

            default:
                field.append(char)
                index = content.index(after: index)
            }
        }

        if !field.isEmpty || !fields.isEmpty || inQuotes {
            endRecord()
        }

        return records
    }
}
