import Foundation
import Testing

@testable import FinanceTracker

@Suite("Money")
struct MoneyTests {
    @Test("Addition gleicher Währung summiert Beträge")
    func addition() {
        let a = Money(amount: Decimal(string: "10.50")!, currency: .eur)
        let b = Money(amount: Decimal(string: "4.25")!, currency: .eur)

        let result = a + b

        #expect(result.amount == Decimal(string: "14.75")!)
        #expect(result.currency == .eur)
    }

    @Test("Subtraktion bildet Differenz")
    func subtraction() {
        let a = Money(amount: 100, currency: .eur)
        let b = Money(amount: Decimal(string: "42.5")!, currency: .eur)

        let result = a - b

        #expect(result.amount == Decimal(string: "57.5")!)
    }

    @Test("Negation dreht Vorzeichen")
    func negation() {
        let money = Money(amount: Decimal(string: "-43.27")!, currency: .eur)

        #expect(money.negated().amount == Decimal(string: "43.27")!)
        #expect(money.isNegative)
        #expect(!money.isPositive)
    }

    @Test("Zero erzeugt Nullbetrag in Zielwährung")
    func zero() {
        let zero = Money.zero(in: .usd)

        #expect(zero.amount == 0)
        #expect(zero.currency == .usd)
    }

    @Test("Codable-Roundtrip erhält Betrag und Währung")
    func codableRoundtrip() throws {
        let money = Money(amount: Decimal(string: "-1234.56")!, currency: .usd)

        let data = try JSONEncoder().encode(money)
        let decoded = try JSONDecoder().decode(Money.self, from: data)

        #expect(decoded == money)
    }
}

@Suite("CurrencyCode")
struct CurrencyCodeTests {
    @Test("Währungscodes werden normalisiert (Großbuchstaben)")
    func normalization() {
        #expect(CurrencyCode("eur") == .eur)
        #expect(CurrencyCode("Usd").rawValue == "USD")
    }
}
