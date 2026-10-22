import Foundation

/// Explizite Währungskonvertierung: Fremdwährungen fließen
/// nur über einen deklarierten Kurs in Basiswährungs-Summen, nie still.
///
/// Produkt-Entscheid (29.08.2026): Fremdwährungs-Transaktionen werden zum
/// Referenzkurs in die Basiswährung umgerechnet und in Analytics/Cashflow
/// mitgezählt. Kurse sind kuratierte statische Richtkurse (1 Einheit → EUR);
/// die UI weist umgerechnete Summen immer als „Referenzkurs“ aus. Währungen
/// ohne Referenzkurs bleiben ausgeschlossen und werden gemeldet, keine
/// stillen Fallback-Werte.
struct CurrencyConverter: Sendable, Equatable {
    /// Calendar date represented by the bundled static reference rates.
    static let referenceEURQuoteDate = Self.referenceDate("2026-08-29")

    private static func referenceDate(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else {
            preconditionFailure("Ungültiges Referenzkursdatum")
        }
        return date
    }

    /// Parst ein Kurs-Literal exakt (keine Float-Umwege: `Decimal(0.92)`
    /// würde die binäre Double-Darstellung einbetten).
    private static func decimal(_ literal: String) -> Decimal {
        guard let value = Decimal(string: literal) else {
            preconditionFailure("Ungültiger Referenzkurs-Literal: \(literal)")
        }
        return value
    }

    /// Kuratierte Richtkurse: 1 Einheit der Währung in EUR (Stand 29.08.2026).
    static let referenceEURRates: [CurrencyCode: Decimal] = [
        CurrencyCode("USD"): decimal("0.92"),
        CurrencyCode("GBP"): decimal("1.17"),
        CurrencyCode("CHF"): decimal("1.06"),
        CurrencyCode("JPY"): decimal("0.0062"),
        CurrencyCode("CAD"): decimal("0.67"),
        CurrencyCode("AUD"): decimal("0.61"),
        CurrencyCode("NZD"): decimal("0.56"),
        CurrencyCode("SEK"): decimal("0.088"),
        CurrencyCode("NOK"): decimal("0.085"),
        CurrencyCode("DKK"): decimal("0.134"),
        CurrencyCode("PLN"): decimal("0.23"),
        CurrencyCode("CZK"): decimal("0.040"),
        CurrencyCode("HUF"): decimal("0.0025"),
        CurrencyCode("RON"): decimal("0.20"),
        CurrencyCode("TRY"): decimal("0.022"),
        CurrencyCode("CNY"): decimal("0.13"),
        CurrencyCode("INR"): decimal("0.011"),
        CurrencyCode("BRL"): decimal("0.17"),
        CurrencyCode("ZAR"): decimal("0.051"),
        CurrencyCode("SGD"): decimal("0.69"),
        CurrencyCode("HKD"): decimal("0.118")
    ]

    private let eurPerUnit: [CurrencyCode: Decimal]

    init(eurPerUnit: [CurrencyCode: Decimal] = CurrencyConverter.referenceEURRates) {
        self.eurPerUnit = eurPerUnit
    }

    /// Multiplikator von `source` nach `target`. `nil` = kein Kurs vorhanden:
    /// der Aufrufer muss den Wert dann explizit ausschließen und melden.
    func rate(from source: CurrencyCode, to target: CurrencyCode) -> Decimal? {
        if source == target { return 1 }
        guard let sourceToEUR = eurRate(of: source),
              let targetToEUR = eurRate(of: target) else { return nil }
        return sourceToEUR / targetToEUR
    }

    /// Konvertiert einen Betrag in die Zielwährung. Gleiche Währung wird
    /// unverändert durchgereicht.
    func convert(_ money: Money, to target: CurrencyCode) -> Money? {
        guard let rate = rate(from: money.currency, to: target) else { return nil }
        return Money(amount: money.amount * rate, currency: target)
    }

    private func eurRate(of currency: CurrencyCode) -> Decimal? {
        if currency == .eur { return 1 }
        return eurPerUnit[currency]
    }
}
