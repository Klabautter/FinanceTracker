import Foundation
import Testing

@testable import FinanceTracker

@Suite("Kontostand aus der Saldo-Spalte")
struct ImportedBalanceExtractorTests {
    private func row(_ day: Int, _ amount: Decimal, balance: Decimal?, currency: CurrencyCode = .eur, status: TransactionStatus = .booked) -> ImportedTransaction {
        ImportedTransaction(
            status: status,
            amount: Money(amount: amount, currency: currency),
            bookedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400),
            balanceAfter: balance
        )
    }

    @Test("Saldo der jüngsten Zeile, unabhängig von der Reihenfolge in der Datei")
    func latestRow() throws {
        let balance = try #require(ImportedBalanceExtractor.latestBalance(in: [
            row(3, -20, balance: 480),
            row(1, -50, balance: 500),
            row(2, 0, balance: nil)
        ], currency: .eur))
        #expect(balance.amount == Money(amount: 480, currency: .eur))
        #expect(balance.source == .file)
        #expect(balance.asOf == Date(timeIntervalSince1970: 1_790_000_000 + 3 * 86_400))
    }

    @Test("Mehrere Zeilen am selben Tag werden über die Saldo-Kette geordnet")
    func sameDayChain() throws {
        // Datei neueste zuerst: 470 folgt auf 480 (480 − 10).
        let balance = try #require(ImportedBalanceExtractor.latestBalance(in: [
            row(3, -10, balance: 470),
            row(3, -20, balance: 480)
        ], currency: .eur))
        #expect(balance.amount.amount == 470)
    }

    @Test("Unklare Reihenfolge ergibt keinen Stand statt eines geratenen")
    func ambiguousSameDay() {
        #expect(ImportedBalanceExtractor.latestBalance(in: [
            row(3, -10, balance: 100),
            row(3, -20, balance: 300)
        ], currency: .eur) == nil)
    }

    @Test("Andere Währung, vorgemerkte Zeilen und fehlender Saldo zählen nicht")
    func ignoredRows() {
        #expect(ImportedBalanceExtractor.latestBalance(in: [
            row(3, -10, balance: 100, currency: .usd),
            row(4, -10, balance: 90, status: .pending),
            row(5, -10, balance: nil)
        ], currency: .eur) == nil)
    }
}
