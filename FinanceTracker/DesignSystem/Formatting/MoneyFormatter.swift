import Foundation

/// Locale-aware Währungsformatierung (WP2).
///
/// FormatStyle-basiert: value-typ, thread-safe, kein mutable Formatter-Cache
/// und nicht an den MainActor gebunden. Keine Business-Konvertierung:
/// der Betrag wird nur dargestellt.
enum MoneyFormatter {
    static func string(_ money: Money, locale: Locale = .current) -> String {
        decimalString(money.amount, currency: money.currency, locale: locale)
    }

    static func signed(_ money: Money, locale: Locale = .current) -> String {
        if money.isNegative {
            return string(money, locale: locale)
        }
        return "+" + string(Money(amount: money.amount, currency: money.currency), locale: locale)
    }

    static func decimalString(
        _ value: Decimal,
        currency: CurrencyCode,
        locale: Locale = .current
    ) -> String {
        let style = Decimal.FormatStyle.Currency(
            code: currency.rawValue,
            locale: locale
        )
        return value.formatted(style)
    }
}
