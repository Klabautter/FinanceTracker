import Foundation

/// Antwort des Beraters: eine vorhandene Kategorie oder, wenn keine passt,
/// der Vorschlag für eine neue. Beides ist nur ein Vorschlag für die
/// Prüfliste; angelegt oder zugeordnet wird erst nach Bestätigung.
enum MerchantCategoryAdvice: Sendable, Equatable {
    case existing(Category.ID)
    case newCategory(name: String, parentID: Category.ID?)
}

/// Schlägt für einen Händlernamen eine Kategorie vor, wenn weder Regeln noch
/// Branchenwörter greifen.
protocol MerchantCategoryAdvisor: Sendable {
    /// Ob auf diesem Gerät gerade ein Modell bereitsteht.
    var isAvailable: Bool { get }

    /// - Parameters:
    ///   - candidates: zuweisbare Kategorien, aus denen gewählt werden soll.
    ///   - parents: Hauptkategorien, unter die eine neue Kategorie passen kann.
    /// - Returns: `nil`, wenn der Name nichts hergibt.
    func adviseCategory(
        merchantName: String,
        isIncome: Bool,
        candidates: [Category],
        parents: [Category]
    ) async -> MerchantCategoryAdvice?
}

/// Prüft einen Vorschlag für eine neue Kategorie gegen den Bestand, damit
/// keine Dubletten und keine händlerspezifischen Mini-Kategorien entstehen.
enum NewCategoryProposalPolicy {
    /// Vergleichsform: klein, ohne Umlaut-Punkte, einfache Plural-Endungen
    /// entfernt („Versicherung" ≈ „Versicherungen").
    static func key(_ name: String) -> String {
        var key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        for suffix in ["en", "n", "e", "s"] where key.count > suffix.count + 3 && key.hasSuffix(suffix) {
            key.removeLast(suffix.count)
            break
        }
        return key
    }

    /// Allgemeinplätze sind keine Kategorie.
    private static let meaninglessNames: Set<String> = [
        "zahlung", "ausgab", "sonstig", "sonstiges", "kategori", "einkauf", "rechnung",
        "dienstleistung", "allgemein", "diver", "unbekannt", "andere"
    ]

    /// Das Modell muss das Branchenwort nennen, und es muss wirklich im
    /// Händlernamen stehen (mindestens vier Zeichen).
    static func isGrounded(evidence: String, in merchantName: String) -> Bool {
        let fold: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
        }
        let word = fold(evidence)
        // Rechtsformen und Orte sagen nichts über die Branche.
        let notIndustry: Set<String> = ["gmbh", "mbh", "gmbhco", "kgaa", "ltd", "limited", "inc", "sarl", "filiale", "deutschland", "germany", "austria", "osterreich"]
        return word.count >= 4 && !notIndustry.contains(word) && fold(merchantName).contains(word)
    }

    /// Bereinigt den vorgeschlagenen Namen; `nil`, wenn er unbrauchbar ist.
    static func cleanedName(_ name: String, merchantName: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = trimmed.split(separator: " ")
        guard !trimmed.isEmpty, trimmed.count <= 30, (1...3).contains(words.count) else { return nil }
        // Ein Händlername ist keine Kategorie.
        guard key(trimmed) != key(merchantName), !meaninglessNames.contains(key(trimmed)) else { return nil }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    /// Wiederholt der Vorschlag nur einen Teil eines vorhandenen Namens
    /// („Essen“ bei „Essen & Trinken“), ist er keine eigene Kategorie.
    static func overlapsExisting(_ name: String, in categories: [Category]) -> Bool {
        let wanted = key(name)
        return categories.contains { category in
            let existing = key(category.name)
            return existing.split(separator: " ").contains { $0.hasPrefix(wanted) || wanted.hasPrefix($0) && $0.count >= 4 }
        }
    }

    /// Eine schon vorhandene Kategorie gleichen Namens hat Vorrang.
    static func existingMatch(for name: String, in categories: [Category]) -> Category? {
        let wanted = key(name)
        return categories.first { key($0.name) == wanted }
    }
}
