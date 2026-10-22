import Foundation

/// Bei Zahlungen über PayPal steht auf dem Kontoauszug PayPal als Empfänger.
/// Der eigentliche Händler steckt im Verwendungszweck:
/// „1052096573908/PP.5628.PP/. dm-drogerie markt GmbH, Ihr Einkauf bei dm-drogerie markt GmbH".
///
/// Ohne Händlernamen (Zahlungen an Freunde, Händler ohne Angabe) bleibt es
/// bei PayPal: es wird nichts geraten.
enum PaymentIntermediaryResolver {
    /// Wie PayPal den Händler im Verwendungszweck ankündigt, je nach Sprache
    /// des Kontos (DE, EN, FR, ES, IT, NL).
    private static let purchaseMarkers = [
        "Ihr Einkauf bei", "Your purchase at", "Votre achat chez", "Su compra en",
        "Il tuo acquisto presso", "Uw aankoop bij"
    ]
    private static let trailingFields = [" EREF:", " MREF:", " CRED:", " SVWZ:", " ABWA:"]

    static func underlyingMerchant(rawMerchantName: String?, rawDescription: String?) -> String? {
        guard let description = rawDescription,
              let marker = purchaseMarkers.lazy.compactMap({
                  description.range(of: $0, options: .caseInsensitive)
              }).first else { return nil }
        let isPayPal = CategoryRuleEngine.normalizedKey(rawMerchantName ?? "").contains("PAYPAL")
            || description.contains("/PP.")
            || CategoryRuleEngine.normalizedKey(description).contains("PAYPAL")
        guard isPayPal else { return nil }

        // Vor „, Ihr Einkauf bei" steht der Name vollständig; danach ist er
        // oft vom 140-Zeichen-Limit des Verwendungszwecks abgeschnitten.
        let before = String(description[..<marker.lowerBound])
        if let name = cleaned(nameBeforeMarker(before)) { return name }

        var after = String(description[marker.upperBound...])
        for field in trailingFields {
            if let range = after.range(of: field) { after = String(after[..<range.lowerBound]) }
        }
        return cleaned(after)
    }

    /// „1052…/PP.5628.PP/. Name," → „Name"
    private static func nameBeforeMarker(_ text: String) -> String {
        var segment = text
        if let separator = segment.range(of: "/. ") {
            segment = String(segment[separator.upperBound...])
        } else if segment.hasPrefix(". ") {
            segment = String(segment.dropFirst(2))
        } else {
            return ""
        }
        return segment.hasSuffix(",") ? String(segment.dropLast()) : segment
    }

    private static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.")))
        guard trimmed.count >= 2,
              !trimmed.uppercased().hasPrefix("EREF"),
              !CategoryRuleEngine.normalizedKey(trimmed).contains("PAYPAL") else { return nil }
        return trimmed
    }
}
