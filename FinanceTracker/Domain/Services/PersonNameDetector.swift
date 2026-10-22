import Foundation
import NaturalLanguage

/// Erkennt, ob ein Händlername eigentlich eine Person ist („Erika
/// Mustermann"). Bei Personen ist jede Überweisung etwas anderes:
/// eine Händler-Regel würde künftige Buchungen falsch zuordnen.
enum PersonNameDetector {
    static func isPersonName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        guard (2...4).contains(words.count),
              trimmed.allSatisfy({ $0.isLetter || $0.isWhitespace || $0 == "," || $0 == "-" || $0 == "." }) else {
            return false
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = trimmed
        var personalSpans = 0
        var otherWords = 0
        tagger.enumerateTags(
            in: trimmed.startIndex..<trimmed.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, _ in
            if tag == .personalName { personalSpans += 1 } else { otherWords += 1 }
            return true
        }
        return personalSpans >= 1 && otherWords == 0
    }
}
