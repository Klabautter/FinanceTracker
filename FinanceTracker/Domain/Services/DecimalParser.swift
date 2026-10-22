import Foundation

/// WP4 (§28-29): Locale-awareer, strikter Decimal-Input-Parser für
/// Edit-Felder. Display-Formatierung (MoneyFormatter) und Edit-Input sind
/// getrennt: dieser Parser akzeptiert reine Zahlen-Eingaben mit de- oder
/// en-Dezimalseparator, nie Währungssymbole als Teil des Werts.
///
/// Finance-Regeln: Unparsebare Werte ergeben `nil` und
/// dürfen niemals still durch Fallbacks ersetzt werden. Der Aufrufer muss
/// bei `nil` den Save blockieren und einen sichtbaren Fehler zeigen.
enum DecimalParser {

    /// Parst eine Betragseingabe zu einem Decimal.
    ///
    /// Akzeptiert: "500", "500,5", "500.5", "1.234,56", "1,234.56",
    /// "1.234.567" (Tausenderpunkte), "1,234,567" (Tausenderkommas),
    /// führende Währungssymbole/Suffixe werden entfernt ("-12,30 €" → -12.30).
    /// Liefert `nil` für leere oder nicht-numerische Eingaben.
    static func parse(_ raw: String) -> Decimal? {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        // Nur Ziffern und Trenner behalten (€/$/Whitespace/Text fallen weg).
        let allowed = CharacterSet(charactersIn: "0123456789.,-")
        input.unicodeScalars.removeAll { !allowed.contains($0) }
        guard !input.isEmpty else { return nil }

        let hasComma = input.contains(",")
        let hasDot = input.contains(".")

        // Mehrfach-Vorkommen: das LETZTE Trennzeichen ist der Dezimalseparator,
        // alle anderen sind Tausendergruppen und werden entfernt.
        if hasComma && hasDot {
            let lastComma = input.lastIndex(of: ",")!
            let lastDot = input.lastIndex(of: ".")!
            let decimalSeparator: Character = lastComma > lastDot ? "," : "."
            let thousands: Character = decimalSeparator == "," ? "." : ","
            input = input.replacingOccurrences(of: String(thousands), with: "")
            input = input.replacingOccurrences(of: String(decimalSeparator), with: ".")
        } else if hasComma {
            let parts = input.components(separatedBy: ",")
            if parts.count == 2 {
                input = parts.joined(separator: ".")
            } else {
                input = parts.joined() // Tausenderkommas
            }
        } else if hasDot {
            let parts = input.components(separatedBy: ".")
            if parts.count > 2 {
                input = parts.joined() // Tausenderpunkte
            }
            // Ein Punkt = Dezimaltrenner (SwiftData-Canonical-Form).
        }

        guard !input.isEmpty, input != "-", input != "." else { return nil }
        return Decimal(string: input, locale: Locale(identifier: "en_US_POSIX"))
    }
}