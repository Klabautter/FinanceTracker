import Foundation
import Testing

@testable import FinanceTracker

@Suite("TransactionCollection Domain")
struct TransactionCollectionTests {
    private let accountID = UUID()
    private let start = Date(timeIntervalSince1970: 1_000)
    private let end = Date(timeIntervalSince1970: 2_000)

    @Test("Collection erzwingt Zeitraum und mindestens ein Konto")
    func invariants() {
        #expect(throws: TransactionCollectionValidationError.emptyAccountIDs) {
            _ = try TransactionCollection(
                name: "Leer",
                systemIconName: "tray",
                startDate: start,
                endDateExclusive: end,
                accountIDs: []
            )
        }
        #expect(throws: TransactionCollectionValidationError.invalidDateRange) {
            _ = try TransactionCollection(
                name: "Falsch",
                systemIconName: "tray",
                startDate: end,
                endDateExclusive: start,
                accountIDs: [accountID]
            )
        }
    }

    @Test("Resolver nutzt halb-offenen Scope und explizite Entscheidungen")
    func resolverSemantics() throws {
        let collection = try TransactionCollection(
            name: "Reise",
            systemIconName: "airplane",
            startDate: start,
            endDateExclusive: end,
            accountIDs: [accountID]
        )
        let resolver = TransactionCollectionResolver()
        let atStart = transaction(accountID: accountID, date: start)
        let atEnd = transaction(accountID: accountID, date: end)
        let otherAccount = transaction(accountID: UUID(), date: start)

        #expect(resolver.contains(atStart, in: collection))
        #expect(!resolver.contains(atEnd, in: collection))
        #expect(!resolver.contains(otherAccount, in: collection))
        #expect(resolver.contains(
            otherAccount,
            in: collection,
            override: TransactionCollectionOverride(
                collectionID: collection.id,
                transactionID: otherAccount.id,
                decision: .include
            )
        ))
        #expect(!resolver.contains(
            atStart,
            in: collection,
            override: TransactionCollectionOverride(
                collectionID: collection.id,
                transactionID: atStart.id,
                decision: .exclude
            )
        ))
    }

    @Test("Summen bleiben je Währung getrennt und Transfers sind neutral")
    func currencyAndCashflowSemantics() {
        let transactions = [
            transaction(accountID: accountID, date: start, kind: .purchase, amount: -20, currency: .eur),
            transaction(accountID: accountID, date: start, kind: .refund, amount: 5, currency: .eur),
            transaction(accountID: accountID, date: start, kind: .transfer, amount: -100, currency: .eur),
            transaction(accountID: accountID, date: start, kind: .purchase, amount: -7, currency: .usd)
        ]

        let summaries = TransactionCollectionSummaryCalculator().summaries(for: transactions)
        #expect(summaries.count == 2)
        #expect(summaries.first { $0.currency == .eur }?.spending == 15)
        #expect(summaries.first { $0.currency == .usd }?.spending == 7)
    }

    private func transaction(
        accountID: UUID,
        date: Date,
        kind: TransactionKind = .purchase,
        amount: Decimal = -1,
        currency: CurrencyCode = .eur
    ) -> Transaction {
        Transaction(
            accountID: accountID,
            source: .manual,
            kind: kind,
            amount: Money(amount: amount, currency: currency),
            bookedAt: date
        )
    }
}
