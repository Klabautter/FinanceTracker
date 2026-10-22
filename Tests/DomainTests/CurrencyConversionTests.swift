import Foundation
import Testing

@testable import FinanceTracker

@Suite("CurrencyConverter")
struct CurrencyConverterTests {
    private let converter = CurrencyConverter()

    private func rounded(_ value: Decimal, scale: Int16) -> Double {
        NSDecimalNumber(decimal: value).rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: scale,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )).doubleValue
    }

    @Test("Gleiche Währung wird unverändert durchgereicht")
    func passthrough() {
        let money = Money(amount: Decimal(string: "-123.45")!, currency: .eur)
        #expect(converter.convert(money, to: .eur) == money)
        #expect(converter.rate(from: .eur, to: .eur) == 1)
    }

    @Test("USD → EUR nutzt den Referenzkurs")
    func usdToEUR() {
        let result = converter.convert(Money(amount: 100, currency: .usd), to: .eur)
        #expect(result?.currency == .eur)
        #expect(result.map({ rounded($0.amount, scale: 6) }) == 92.0)
    }

    @Test("EUR → USD ist die Kehrfunktion des Referenzkurses")
    func eurToUSD() {
        // 92 EUR ÷ 0.92 = 100 USD (exakt)
        let result = converter.convert(Money(amount: 92, currency: .eur), to: .usd)
        #expect(result?.currency == .usd)
        #expect(result.map({ rounded($0.amount, scale: 6) }) == 100.0)
    }

    @Test("Fremdwährung → Fremdwährung läuft über den EUR-Pivot")
    func crossCurrencyViaPivot() {
        // 100 USD × (0.92 / 1.17) ≈ 78.63247863 GBP
        let result = converter.convert(Money(amount: 100, currency: .usd), to: .gbp)
        #expect(result?.currency == .gbp)
        let doubleValue = result.map({ NSDecimalNumber(decimal: $0.amount).doubleValue }) ?? 0
        #expect(abs(doubleValue - 78.63247863) < 0.000001)
    }

    @Test("Währung ohne Referenzkurs liefert nil (kein stiller Fallback)")
    func unknownCurrencyReturnsNil() {
        let exotic = Money(amount: 50, currency: CurrencyCode("XYZ"))
        #expect(converter.convert(exotic, to: .eur) == nil)
        #expect(converter.rate(from: CurrencyCode("XYZ"), to: .eur) == nil)
        #expect(converter.convert(Money(amount: 50, currency: .eur), to: CurrencyCode("XYZ")) == nil)
    }

    @Test("Referenztabelle ist vollständig positiv und deckt die Hauptwährungen ab")
    func referenceTableSanity() {
        for (currency, rate) in CurrencyConverter.referenceEURRates {
            #expect(rate > 0, "Referenzkurs für \(currency.rawValue) muss positiv sein")
        }
        #expect(CurrencyConverter.referenceEURRates[.usd] != nil)
        #expect(CurrencyConverter.referenceEURRates[.gbp] != nil)
        #expect(CurrencyConverter.referenceEURRates[CurrencyCode("CHF")] != nil)
    }
}
