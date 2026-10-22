import Foundation
import Testing

@testable import FinanceTracker

@Suite("TransactionQuery")
struct TransactionQueryTests {
    private let accountA = UUID()
    private let categoryFood = UUID()

    private func makeTransaction(
        merchant: String = "REWE",
        rawDescription: String? = nil,
        amount: Decimal = -10,
        bookedAt: Date? = Date(timeIntervalSince1970: 1_750_000_000),
        accountID: UUID? = nil,
        categoryID: UUID? = nil,
        status: TransactionStatus = .booked
    ) -> Transaction {
        Transaction(
            accountID: accountID ?? self.accountA,
            source: .demo,
            status: status,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: bookedAt,
            rawDescription: rawDescription,
            rawMerchantName: merchant,
            categoryID: categoryID
        )
    }

    @Test("Suchtext matcht Händler und Beschreibung, case-insensitiv")
    func searchText() {
        let query = TransactionQuery(searchText: "rewe")
        let txn = makeTransaction(rawDescription: "REWE SAGT DANKE")

        #expect(query.matches(txn))
        #expect(!query.matches(makeTransaction(merchant: "SHELL", rawDescription: "Shell Station")))
    }

    @Test("Kategorie-Filter schließt Transaktionen ohne Kategorie aus")
    func categoryFilter() {
        var query = TransactionQuery()
        query.categoryIDs = [categoryFood]

        let withCategory = makeTransaction(categoryID: categoryFood)
        let withoutCategory = makeTransaction()

        #expect(query.matches(withCategory))
        #expect(!query.matches(withoutCategory))
    }

    @Test("Datumsintervall filtert nach Anzeigedatum")
    func dateInterval() {
        var query = TransactionQuery()
        query.dateInterval = DateInterval(
            start: Date(timeIntervalSince1970: 1_740_000_000),
            end: Date(timeIntervalSince1970: 1_750_500_000)
        )

        #expect(query.matches(makeTransaction()))
        #expect(query.matches(makeTransaction(bookedAt: Date(timeIntervalSince1970: 1_740_000_000))))
        #expect(!query.matches(makeTransaction(bookedAt: Date(timeIntervalSince1970: 1_750_500_000))))
        #expect(!query.matches(makeTransaction(bookedAt: Date(timeIntervalSince1970: 1_600_000_000))))
    }

    @Test("Datumsintervall bleibt über den Sommerzeitwechsel halb offen")
    func dateIntervalAcrossDSTIsHalfOpen() {
        var vienna = Calendar(identifier: .gregorian)
        vienna.timeZone = TimeZone(identifier: "Europe/Vienna")!
        let start = vienna.date(from: DateComponents(year: 2026, month: 3, day: 29))!
        let end = vienna.date(byAdding: .day, value: 1, to: start)!
        var query = TransactionQuery()
        query.dateInterval = DateInterval(start: start, end: end)

        #expect(end.timeIntervalSince(start) == 23 * 60 * 60)
        #expect(query.matches(makeTransaction(bookedAt: start)))
        #expect(query.matches(makeTransaction(bookedAt: end.addingTimeInterval(-0.001))))
        #expect(!query.matches(makeTransaction(bookedAt: end)))
    }

    @Test("Status-Filter berücksichtigt Pending")
    func statusFilter() {
        var query = TransactionQuery()
        query.statuses = [.booked]

        #expect(query.matches(makeTransaction(status: .booked)))
        #expect(!query.matches(makeTransaction(status: .pending)))
    }

    @Test("applying sortiert absteigend und begrenzt Ergebnis")
    func applyingSortAndLimit() {
        let older = makeTransaction(bookedAt: Date(timeIntervalSince1970: 100))
        let newer = makeTransaction(bookedAt: Date(timeIntervalSince1970: 200))

        var query = TransactionQuery()
        query.limit = 1
        let result = query.applying(to: [older, newer])

        #expect(result.count == 1)
        #expect(result.first?.id == newer.id)
    }
}
