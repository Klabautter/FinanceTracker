import Foundation
import Testing

@testable import FinanceTracker

@Suite("Enable Banking: Kontostand")
struct EnableBankingBalanceTests {
    private func balances(_ json: String) throws -> [EnableBankingBalance] {
        try JSONDecoder().decode(EnableBankingBalancesResponse.self, from: Data(json.utf8)).balances
    }

    @Test("Gebuchter Stand vor verfügbarem (der kann den Kreditrahmen enthalten)")
    func prefersBooked() throws {
        let list = try balances("""
        {"balances": [
          {"balance_type": "ITAV", "balance_amount": {"amount": "5500.00", "currency": "EUR"}},
          {"balance_type": "CLBD", "balance_amount": {"amount": "1234.56", "currency": "EUR"}}
        ]}
        """)
        #expect(EnableBankingBankDataProvider.preferredBalance(list, currency: .eur) == Money(amount: Decimal(string: "1234.56")!, currency: .eur))
    }

    @Test("Nur Kontowährung, unlesbarer Betrag ergibt keinen Stand")
    func currencyAndInvalid() throws {
        let other = try balances("""
        {"balances": [{"balance_type": "CLBD", "balance_amount": {"amount": "10.00", "currency": "USD"}}]}
        """)
        #expect(EnableBankingBankDataProvider.preferredBalance(other, currency: .eur) == nil)
        let invalid = try balances("""
        {"balances": [{"balance_type": "CLBD", "balance_amount": {"amount": "n/a", "currency": "EUR"}}]}
        """)
        #expect(EnableBankingBankDataProvider.preferredBalance(invalid, currency: .eur) == nil)
    }
}
