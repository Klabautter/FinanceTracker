import Foundation

/// Vorschlag für noch unkategorisierte Transaktionen: die am häufigsten
/// vergebene Kategorie desselben Händlers aus bereits kategorisierten
/// Buchungen (Verlauf). Rein, deterministisch, ohne I/O: das Model lädt
/// den begrenzten Verlauf (`recentTransactions`), der Service rechnet.
///
/// Entscheidend: Die Ähnlichkeit folgt exakt der Lernregel-Semantik
/// (`CategoryRule.makeFromCorrection`: variable Tokens wie Filialnummern
/// werden gestrippt, Händler-IDs exakt gematcht). Was der Vorschlag
/// verspricht („REWE 111“ ≈ „REWE 999“), hält der Merkregel-Pfad danach
/// auch: dieselbe Regel wird beim Übernehmen persistiert.
///
/// Kein Ersatz für Regeln: Wer den Vorschlag übernimmt, bekommt zugleich
/// die Händler-Merkregel (Scope `.merchant` im Model): danach taucht der
/// Händler nie wieder in der Queue auf.
struct CategorySuggestion: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
        /// Aus bereits kategorisierten Buchungen desselben Händlers.
        case history
        /// Vom Sprachmodell des Geräts aus dem Händlernamen gelesen.
        case deviceModel
    }

    let categoryID: Category.ID
    /// Anzahl kategorisierter Verlauf-Buchungen, die den Vorschlag stützen.
    let supportCount: Int
    var origin: Origin = .history
}

struct CategorySuggestionService: Sendable {
    /// Begrenzt die Regelableitung aus dem Verlauf (Schutz vor
    /// pathologischem Verlauf; der Aufrufer lädt ohnehin begrenzt).
    static let maxHistoryScan = 5000

    /// Liefert pro unkategorisierter Transaktions-ID den Modus der
    /// Verlauf-Kategorien aller passenden Lernregeln, nur zuweisbare
    /// Leaves (Parents sind aggregation-only), nur bei Support ≥ 1.
    /// Gleichstand wird deterministisch per Kategorie-UUID gebrochen.
    /// Jede Verlauf-Buchung stimmt einmal ab (gleiche Händler → N Stimmen).
    func suggestions(
        uncategorized: [Transaction],
        history: [Transaction],
        categories: [Category]
    ) -> [Transaction.ID: CategorySuggestion] {
        let assignableIDs = Set(CategoryHierarchy().assignableCategories(in: categories).map(\.id))
        guard !assignableIDs.isEmpty, !uncategorized.isEmpty else { return [:] }

        let historyRules = history.prefix(Self.maxHistoryScan).compactMap { txn -> CategoryRule? in
            guard let categoryID = txn.categoryID, assignableIDs.contains(categoryID) else { return nil }
            return CategoryRule.makeFromCorrection(
                transaction: txn,
                categoryID: categoryID,
                existingRules: []
            )
        }
        guard !historyRules.isEmpty else { return [:] }
        let compiled = CategoryRuleEngine().compile(historyRules)

        var result: [Transaction.ID: CategorySuggestion] = [:]
        for txn in uncategorized {
            var votes: [Category.ID: Int] = [:]
            for match in compiled.allMatches(for: txn) {
                guard assignableIDs.contains(match.categoryID) else { continue }
                votes[match.categoryID, default: 0] += 1
            }
            guard !votes.isEmpty else { continue }
            let best = votes.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key.uuidString < $1.key.uuidString
            }[0]
            result[txn.id] = CategorySuggestion(categoryID: best.key, supportCount: best.value)
        }
        return result
    }
}
