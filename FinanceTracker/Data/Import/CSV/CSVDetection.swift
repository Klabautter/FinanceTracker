import Foundation

enum CSVDetection {
    static let candidateDelimiters: [Character] = [",", ";", "\t"]

    /// Trennzeichen mit der stimmigsten Tabellenstruktur in den ersten Zeilen.
    /// Bankexporte beginnen oft mit Kopfzeilen (Kontoname, Zeitraum), die
    /// kaum Trennzeichen enthalten: die erste Zeile allein führt dort in die
    /// Irre. Bei Gleichstand entscheidet die erste Zeile.
    static func detectDelimiter(in content: String) -> Character {
        let lines = content
            .split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
            .prefix(30)
        guard let firstLine = lines.first else { return "," }

        var best: Character = ","
        var bestScore = 0
        var bestFirstLineCount = 0
        for delimiter in candidateDelimiters {
            var linesByCount: [Int: Int] = [:]
            for line in lines {
                let count = line.filter { $0 == delimiter }.count
                if count > 0 { linesByCount[count, default: 0] += 1 }
            }
            let score = linesByCount.map { $0.key * $0.value }.max() ?? 0
            let firstLineCount = firstLine.filter { $0 == delimiter }.count
            if score > bestScore || (score == bestScore && firstLineCount > bestFirstLineCount) {
                best = delimiter
                bestScore = score
                bestFirstLineCount = firstLineCount
            }
        }
        return best
    }

    /// Vergleichsform einer Spaltenüberschrift: klein, ohne Umlaut-Punkte,
    /// Satz- und Trennzeichen als Leerzeichen („Betrag (EUR)" → „betrag eur",
    /// „transaction_id" → „transaction id").
    static func comparisonKey(_ header: String) -> String {
        header
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalizedHeaders(_ headers: [String]) -> [String] {
        headers.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .lowercased()
        }
    }

    static func containsAll(_ headers: [String], required: Set<String>) -> Bool {
        let normalized = Set(normalizedHeaders(headers))
        return required.isSubset(of: normalized)
    }
}
