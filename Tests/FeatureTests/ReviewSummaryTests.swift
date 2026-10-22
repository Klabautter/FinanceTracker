import Foundation
import Testing

@testable import FinanceTracker

/// WP13/WP14 (§99-100, §104): Review-Counts sind GLOBAL korrekt und
/// dashboard/queue-konsistent; die Queue erreicht ältere offene Reviews
/// über die leichte Projection statt Full-History-Hydration.
@MainActor
@Suite("ReviewSummary")
struct ReviewSummaryTests {

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func txn(
        accountID: UUID,
        merchant: String,
        daysAgo: Int,
        categoryID: UUID? = nil,
        reviewed: Bool = false,
        currency: CurrencyCode = .eur
    ) -> Transaction {
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 29))!
        var txn = Transaction(
            accountID: accountID,
            source: .manual,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(10 + daysAgo % 20), currency: currency),
            bookedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: base)!,
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
        txn.categoryID = categoryID
        txn.reviewed = reviewed
        return txn
    }

    @Test("Globale Summary zählt auch Reviews außerhalb des 6-Monats-Fensters (§96/§99)")
    func globalCountIncludesOlderReviews() async throws {
        let dependencies = try makeDependencies()
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        // 3 offene Reviews im 6-Monats-Fenster + 2 SEHR alte offene Reviews
        // (über 6 Monate zurück) + 2 geprüfte.
        var transactions: [Transaction] = []
        transactions.append(txn(accountID: account.id, merchant: "Aktuell A", daysAgo: 10))
        transactions.append(txn(accountID: account.id, merchant: "Aktuell B", daysAgo: 20))
        transactions.append(txn(accountID: account.id, merchant: "Aktuell C", daysAgo: 30))
        transactions.append(txn(accountID: account.id, merchant: "Alt A", daysAgo: 250))
        transactions.append(txn(accountID: account.id, merchant: "Alt B", daysAgo: 400))
        transactions.append(txn(accountID: account.id, merchant: "Geprüft A", daysAgo: 15, reviewed: true))
        transactions.append(txn(accountID: account.id, merchant: "Geprüft B", daysAgo: 300, reviewed: true))
        try await dependencies.transactionRepository.upsert(transactions)

        // Gleicher Pfad wie DashboardModel: leichte Projection + Summary.
        let lightRows = try await dependencies.transactionRepository.reviewCandidateTransactions()
        #expect(lightRows.count == 7)

        let summary = ReviewQueueBuilder().buildSummary(
            transactions: lightRows,
            baseCurrency: .eur
        )
        #expect(summary.uncategorizedCount == 5)
        #expect(summary.totalCount == 5, "Auch die 2 alten offenen Reviews müssen zählen")
    }

    @Test("Dashboard-Summary und Queue-Items sind konsistent (§99/§104)")
    func summaryMatchesQueueItems() async throws {
        let dependencies = try makeDependencies()
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        // Fremdwährungs-Txn erzeugt einen Review-Kandidaten; außerdem 2
        // ohne Kategorie, einer davon SEHR alt.
        var transactions: [Transaction] = []
        transactions.append(txn(accountID: account.id, merchant: "Alt", daysAgo: 300))
        transactions.append(txn(accountID: account.id, merchant: "Neu", daysAgo: 5))
        transactions.append(txn(
            accountID: account.id,
            merchant: "US Shop",
            daysAgo: 200,
            currency: .usd
        ))
        try await dependencies.transactionRepository.upsert(transactions)

        // Dashboard-Pfad.
        let lightRows = try await dependencies.transactionRepository.reviewCandidateTransactions()
        let summary = ReviewQueueBuilder().buildSummary(
            transactions: lightRows,
            baseCurrency: .eur
        )

        // Queue-Pfad.
        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()

        // Die USD-Txn erzeugt ZWEI Items (uncategorized + foreignCurrency,
        // builder-Semantik pro Grund), also: uncategorized 3 + FX 1 = 4.
        #expect(summary.uncategorizedCount == 3)
        #expect(summary.foreignCurrencyCount == 1)
        #expect(summary.totalCount == 4)
        #expect(model.items.count == summary.totalCount, "Queue-Items und Dashboard-Count müssen übereinstimmen")
    }

    @Test("Leichte Projection trägt die Review-relevanten Felder korrekt")
    func lightProjectionFields() async throws {
        let dependencies = try makeDependencies()
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let category = FinanceTracker.Category(name: "Kat", systemIconName: "tag")
        try await dependencies.categoryRepository.upsert([category])

        var txn = txn(
            accountID: account.id,
            merchant: "Test Händler",
            daysAgo: 3,
            categoryID: category.id,
            reviewed: true,
            currency: .usd
        )
        txn.note = "Leichte-Notiz"
        try await dependencies.transactionRepository.upsert([txn])

        let lightRows = try await dependencies.transactionRepository.reviewCandidateTransactions()
        let row = try #require(lightRows.first)
        #expect(row.id == txn.id)
        #expect(row.status == .booked)
        #expect(row.categoryID == category.id)
        #expect(row.reviewed == true)
        #expect(row.amount.currency == .usd)
        #expect(row.effectiveMerchantName == "Test Händler")
    }
}