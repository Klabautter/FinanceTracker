import Foundation

/// Erkennt eine Buchung, die auf demselben Konto schon aus einer anderen
/// Quelle vorliegt, z. B. erst als PDF-Auszug und später als CSV-Export
/// derselben Karte importiert.
///
/// Die Quellen beschreiben dieselbe Zahlung unterschiedlich: Das Datum kann
/// Zahlungs- oder Buchungstag sein, der Händlertext ist mal gekürzt, mal
/// vollständig. Verglichen werden deshalb Konto, Währung und exakter Betrag,
/// ein Datum in wenigen Tagen Abstand und ein ähnlicher Händlertext.
struct CrossSourceDuplicateMatcher: Sendable {
    static let dateTolerance: TimeInterval = 3 * 24 * 3600

    /// Die zeitlich nächste passende Buchung; `nil`, wenn keine passt. Welche
    /// Buchungen überhaupt in Frage kommen (andere Quelle oder anderes
    /// Dateiformat), entscheidet der Aufrufer.
    func match(_ incoming: Transaction, among candidates: [Transaction]) -> Transaction? {
        candidates
            .filter { candidate in
                candidate.accountID == incoming.accountID
                    && candidate.status != .cancelled
                    && candidate.status != .reversed
                    && candidate.amount.currency == incoming.amount.currency
                    && candidate.amount.amount == incoming.amount.amount
                    && distance(candidate, incoming) <= Self.dateTolerance
                    && merchantsAreSimilar(candidate, incoming)
            }
            .min { distance($0, incoming) < distance($1, incoming) }
    }

    private func distance(_ lhs: Transaction, _ rhs: Transaction) -> TimeInterval {
        abs(lhs.displayDate.timeIntervalSince(rhs.displayDate))
    }

    /// Gleich, enthalten oder mindestens ein gemeinsames Namenswort, wobei
    /// ein Wort auch Anfang des anderen sein darf („MCDONALDS 155“ und
    /// „McDonald's Wien“ teilen „MCDONALD“). Zahlen wie Filialnummern zählen
    /// nicht.
    private func merchantsAreSimilar(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
        let left = CategoryRuleEngine.normalizedKey(lhs.rawMerchantName ?? lhs.rawDescription ?? "")
        let right = CategoryRuleEngine.normalizedKey(rhs.rawMerchantName ?? rhs.rawDescription ?? "")
        guard !left.isEmpty, !right.isEmpty else { return true }
        if left.contains(right) || right.contains(left) { return true }
        let rightWords = words(right)
        return words(left).contains { word in
            rightWords.contains { $0.hasPrefix(word) || word.hasPrefix($0) }
        }
    }

    private func words(_ key: String) -> [String] {
        key.split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 4 && !$0.allSatisfy(\.isNumber) }
    }
}
