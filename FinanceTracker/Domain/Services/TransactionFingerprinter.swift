import CryptoKit
import Foundation

enum TransactionFingerprinter {
    private static let formatterBox = FingerprintFormatterBox()

    static func fingerprint(
        source: TransactionSource,
        accountID: UUID,
        bookingDate: Date?,
        amount: Money,
        merchantOrDescription: String?,
        balanceAfter: Decimal? = nil,
        occurrence: Int = 1
    ) -> String {
        var parts = [
            source.rawValue,
            accountID.uuidString,
            bookingDate.map { formatterBox.dayFormatter.string(from: $0) } ?? "",
            canonicalAmount(amount),
            amount.currency.rawValue,
            normalizedText(merchantOrDescription ?? "")
        ]
        // Der Kontostand nach der Buchung unterscheidet zwei sonst gleiche
        // Buchungen desselben Tages (zweimal derselbe Einkauf) und bleibt
        // über sich überlappende Auszüge hinweg gleich. Ohne Kontostand
        // bleibt der Fingerprint unverändert.
        if let balanceAfter {
            parts.append("saldo:" + canonicalAmount(Money(amount: balanceAfter, currency: amount.currency)))
        }
        // Zweimal derselbe Einkauf am selben Tag in einer Datei: Die zweite
        // Zeile ist eine eigene Buchung, keine Dublette. Sie zählt mit, bei
        // erneutem Import derselben Datei bekommt sie wieder dieselbe Nummer.
        if occurrence > 1 {
            parts.append("nr:\(occurrence)")
        }
        let canonical = parts.joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Source-agnostischer Fingerprint für den Cross-Source-Hinweis
    /// (CSV vs. openBanking, gleiche reale Buchung, andere Quelle).
    ///
    /// Bewusst KEIN stilles Mergen: Ein Match markiert nur
    /// einen `ImportRowIssue`/Review-Kandidaten, die Zeile wird trotzdem
    /// importiert (heutiges Verhalten: 2 Einträge). Account, Tag, Betrag,
    /// Währung und Text bleiben Pflichtbestandteile.
    static func crossSourceFingerprint(
        accountID: UUID,
        bookingDate: Date?,
        amount: Money,
        merchantOrDescription: String?
    ) -> String {
        let parts = [
            accountID.uuidString,
            bookingDate.map { formatterBox.dayFormatter.string(from: $0) } ?? "",
            canonicalAmount(amount),
            amount.currency.rawValue,
            normalizedText(merchantOrDescription ?? "")
        ]
        let canonical = parts.joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Kanonische Betragsdarstellung für den Fingerprint.
    ///
    /// `Decimal.description` trägt je nach Entstehung (String-Parsing vs.
    /// Rechenweg) unterschiedliche Skalen; `NSDecimalNumber.stringValue`
    /// normalisiert Trailing-Zeros ohne zu runden (kein
    /// Fallback, keine Identitätsrundung). Money bleibt Decimal (#3).
    /// `-5.00 == -5.0`, aber `-10.004 != -10`; `-0` wird zu `0`.
    static func canonicalAmount(_ money: Money) -> String {
        let normalized = NSDecimalNumber(decimal: money.amount).stringValue
        return normalized == "-0" ? "0" : normalized
    }

    private static func normalizedText(_ input: String) -> String {
        input.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}


final class FingerprintFormatterBox: @unchecked Sendable {
    let dayFormatter: ISO8601DateFormatter

    init() {
        dayFormatter = ISO8601DateFormatter()
        dayFormatter.formatOptions = [.withYear, .withMonth, .withDay]
    }
}
