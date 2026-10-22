import Foundation

struct CurrencyCode: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    static let eur = CurrencyCode("EUR")
    static let usd = CurrencyCode("USD")
    static let gbp = CurrencyCode("GBP")

    /// P2: Angebotene Währungen für manuelle Eingaben (Gruppenanteile,
    /// manuelle Buchungen). Bewusst eine kuratierte Liste statt aller
    /// ISO-4217-Codes, kein FX-Versprechen (#35: ohne Referenzkurs keine
    /// Umrechnung, fremde Währungen bleiben getrennt).
    static let offered: [CurrencyCode] = [
        .eur, .usd, .gbp, .init("CHF"), .init("SEK"), .init("NOK"),
        .init("DKK"), .init("PLN"), .init("CZK"), .init("HUF"),
        .init("JPY"), .init("CAD"), .init("AUD"),
    ]

    var description: String { rawValue }
}
