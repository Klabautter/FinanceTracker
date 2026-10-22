import Foundation

/// Bankauswahl: In Deutschland liefert der Anbieter mehrere tausend Institute
/// (jede Sparkasse und Volksbank einzeln). Statt alle zu zeigen, gibt es eine
/// Suche mit Rangfolge und für den Einstieg die bekanntesten Banken.
enum BankInstitutionSearch {
    struct Result: Sendable, Equatable {
        let matches: [BankInstitution]
        /// Treffer insgesamt: mehr als `matches`, wenn gekürzt wurde.
        let totalCount: Int
        /// Treffer, in denen die Suche als ganzes Wort steht („ING", nicht
        /// „Göttingen"): zeigt, ob ein Stichwort eine Bankengruppe ist.
        var wholeWordCount = 0

        var hiddenCount: Int { totalCount - matches.count }
    }

    /// Treffer nach Güte: Name beginnt mit der Suche als ganzem Wort („ING"
    /// vor „Ingolstadt"), dann ganzes Wort irgendwo, dann Name beginnt damit,
    /// dann ein Wort beginnt damit, dann irgendwo.
    /// Groß-/Kleinschreibung und Akzente zählen nicht („raiffeisen" findet
    /// „Raiffeisenbank Oberösterreich").
    static func search(_ query: String, in institutions: [BankInstitution], limit: Int = 50) -> Result {
        let needle = normalized(query)
        guard !needle.isEmpty else { return Result(matches: [], totalCount: 0, wholeWordCount: 0) }
        let paddedNeedle = " \(words(needle).joined(separator: " ")) "
        var ranked: [(rank: Int, institution: BankInstitution)] = []
        for institution in institutions {
            let name = normalized(institution.name)
            let nameWords = words(name)
            let paddedName = " \(nameWords.joined(separator: " ")) "
            if paddedName.hasPrefix(paddedNeedle) {
                ranked.append((0, institution))
            } else if paddedName.contains(paddedNeedle) {
                ranked.append((1, institution))
            } else if name.hasPrefix(needle) {
                ranked.append((2, institution))
            } else if nameWords.contains(where: { $0.hasPrefix(needle) }) {
                ranked.append((3, institution))
            } else if name.contains(needle) {
                ranked.append((4, institution))
            }
        }
        // Stabil: innerhalb einer Stufe bleibt die alphabetische Reihenfolge.
        let sorted = ranked.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.institution)
        return Result(
            matches: Array(sorted.prefix(limit)),
            totalCount: sorted.count,
            wholeWordCount: ranked.filter { $0.rank <= 1 }.count
        )
    }

    /// Bekannte Banken je Land, in dieser Reihenfolge. Es wird nach Wörtern
    /// im Namen gesucht, weil der Anbieter die genaue Schreibweise vorgibt.
    static let popularKeywords: [String: [String]] = [
        "DE": ["DKB", "ING", "Sparkasse", "Volksbank", "Commerzbank", "Deutsche Bank", "Postbank",
               "comdirect", "N26", "Consorsbank", "HypoVereinsbank", "Targobank", "C24", "Revolut"],
        "AT": ["Erste Bank", "Raiffeisen", "Bank Austria", "BAWAG", "easybank", "Volksbank", "N26", "Revolut"],
        "CH": ["UBS", "PostFinance", "Raiffeisen", "Zürcher Kantonalbank", "Revolut"],
        "NL": ["ING", "ABN AMRO", "Rabobank", "bunq", "SNS", "Revolut"],
        "FR": ["BNP Paribas", "Crédit Agricole", "Société Générale", "Boursorama", "LCL", "Revolut"],
        "ES": ["Santander", "BBVA", "CaixaBank", "Sabadell", "ING", "Revolut"],
        "IT": ["Intesa Sanpaolo", "UniCredit", "Fineco", "BPER", "Revolut"]
    ]

    /// Ab so vielen Treffern ist ein Stichwort eine Bankengruppe (jede
    /// Sparkasse einzeln) und keine einzelne Bank.
    static let groupThreshold = 4

    /// Die bekanntesten Banken eines Landes: pro Stichwort der beste Treffer.
    /// Bankengruppen wie „Sparkasse" fehlen hier: Welche gemeint ist, weiß
    /// nur der Nutzer, dafür gibt es `groupShortcuts`.
    static func popular(in institutions: [BankInstitution], country: String) -> [BankInstitution] {
        var seen = Set<String>()
        var result: [BankInstitution] = []
        for keyword in popularKeywords[country.uppercased()] ?? [] {
            let found = search(keyword, in: institutions, limit: 1)
            guard found.wholeWordCount < groupThreshold,
                  let match = found.matches.first,
                  seen.insert(match.id).inserted else { continue }
            result.append(match)
        }
        return result
    }

    /// Stichwörter für Bankengruppen („Sparkasse", „Volksbank"): Ein Klick
    /// startet die Suche, der Nutzer ergänzt den Ort.
    static func groupShortcuts(in institutions: [BankInstitution], country: String) -> [String] {
        (popularKeywords[country.uppercased()] ?? []).filter {
            search($0, in: institutions, limit: 1).wholeWordCount >= groupThreshold
        }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
