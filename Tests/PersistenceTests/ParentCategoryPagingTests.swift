import Foundation
import Testing

@testable import FinanceTracker

/// WP8 (§67-68): Parent-Category-Filter über die GESAMTE Pagination
/// der Descendant-Filter darf beim Paging nicht verloren gehen.
@MainActor
@Suite("ParentCategoryPaging")
struct ParentCategoryPagingTests {

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func txn(
        accountID: UUID,
        categoryID: UUID?,
        merchant: String,
        dayOffset: Int,
        tagIDs: [UUID] = []
    ) -> Transaction {
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 30))!
        var txn = Transaction(
            accountID: accountID,
            source: .manual,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(dayOffset + 1), currency: .eur),
            bookedAt: Calendar.current.date(byAdding: .day, value: -dayOffset, to: base)!,
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
        txn.categoryID = categoryID
        txn.tagIDs = tagIDs
        return txn
    }

    @Test("Parent A über 600 Txns und 2 Seiten: nur A-Descendants, keine B1, kein Overlap")
    func parentFilterAcrossPages() async throws {
        let dependencies = try makeDependencies()

        let parentA = FinanceTracker.Category(name: "A", systemIconName: "folder")
        let childA1 = FinanceTracker.Category(name: "A1", systemIconName: "tag", parentID: parentA.id)
        let childA2 = FinanceTracker.Category(name: "A2", systemIconName: "tag", parentID: parentA.id)
        let parentB = FinanceTracker.Category(name: "B", systemIconName: "folder")
        let childB1 = FinanceTracker.Category(name: "B1", systemIconName: "tag", parentID: parentB.id)
        try await dependencies.categoryRepository.upsert([parentA, childA1, childA2, parentB, childB1])

        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        // 600 Txns, eindeutige Daten (global deterministische Reihenfolge),
        // Kategorien im Wechsel: A1, A2, ParentA, B1.
        var transactions: [Transaction] = []
        for i in 0..<600 {
            let categoryID: UUID
            let merchant: String
            switch i % 4 {
            case 0: categoryID = childA1.id; merchant = "Händler A1"
            case 1: categoryID = childA2.id; merchant = "Händler A2"
            case 2: categoryID = parentA.id; merchant = "Händler A-Parent"
            default: categoryID = childB1.id; merchant = "Händler B1"
            }
            transactions.append(txn(
                accountID: account.id,
                categoryID: categoryID,
                merchant: merchant,
                dayOffset: i
            ))
        }
        try await dependencies.transactionRepository.upsert(transactions)

        let descendants = CategoryHierarchy().descendantIDs(of: parentA.id, in: try await dependencies.categoryRepository.categories())
        #expect(descendants.count == 3) // ParentA + A1 + A2

        var query = TransactionQuery()
        query.categoryIDs = descendants

        let page1 = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .dateDescending, offset: 0, limit: 300
        )
        let page2 = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .dateDescending, offset: 300, limit: 300
        )

        let all = page1.transactions + page2.transactions
        // Exakt: 600 Txns im 4er-Wechsel → 150×A1 + 150×A2 + 150×ParentA
        // + 150×B1. Der ParentA-Filter muss genau 450 liefern.
        #expect(all.count == 450)
        let bCount = all.filter { $0.categoryID == childB1.id }.count
        #expect(bCount == 0, "B1 darf im Parent-A-Filter nicht erscheinen")
        let aCount = all.count { $0.categoryID == childA1.id || $0.categoryID == childA2.id || $0.categoryID == parentA.id }
        #expect(aCount == all.count)
        #expect(page1.hasMore)

        // Kein Overlap und keine Lücke zwischen den Seiten.
        let ids1 = Set(page1.transactions.map(\.id))
        let ids2 = Set(page2.transactions.map(\.id))
        #expect(ids1.isDisjoint(with: ids2))

        // Globale Datum-Sortierung über beide Seiten.
        let dates = all.map(\.displayDate)
        #expect(dates == dates.sorted(by: >))
    }

    @Test("Search + Parent-Filter kombinieren sich korrekt")
    func searchPlusParent() async throws {
        let dependencies = try makeDependencies()

        let parentA = FinanceTracker.Category(name: "A", systemIconName: "folder")
        let childA1 = FinanceTracker.Category(name: "A1", systemIconName: "tag", parentID: parentA.id)
        let childB1 = FinanceTracker.Category(name: "B1", systemIconName: "tag")
        try await dependencies.categoryRepository.upsert([parentA, childA1, childB1])

        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        var transactions: [Transaction] = []
        for i in 0..<50 {
            transactions.append(txn(
                accountID: account.id,
                categoryID: i % 2 == 0 ? childA1.id : childB1.id,
                merchant: "Sonderhaus",
                dayOffset: i
            ))
        }
        try await dependencies.transactionRepository.upsert(transactions)

        var query = TransactionQuery()
        query.categoryIDs = CategoryHierarchy().descendantIDs(of: parentA.id, in: try await dependencies.categoryRepository.categories())
        query.searchText = "sonderhaus"

        let page = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .dateDescending, offset: 0, limit: 300
        )
        #expect(page.transactions.count == 25)
        #expect(page.transactions.allSatisfy { $0.categoryID == childA1.id })
    }

    @Test("Sort + Parent-Filter: globale Merchant-Sortierung bleibt korrekt")
    func sortPlusParent() async throws {
        let dependencies = try makeDependencies()

        let parentA = FinanceTracker.Category(name: "A", systemIconName: "folder")
        let childA1 = FinanceTracker.Category(name: "A1", systemIconName: "tag", parentID: parentA.id)
        let childB1 = FinanceTracker.Category(name: "B1", systemIconName: "tag")
        try await dependencies.categoryRepository.upsert([parentA, childA1, childB1])

        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        var transactions: [Transaction] = []
        for i in 0..<100 {
            let merchant = i % 2 == 0 ? "Alpha Markt" : "Zeta Markt"
            transactions.append(txn(
                accountID: account.id,
                categoryID: i % 3 == 0 ? childB1.id : childA1.id,
                merchant: merchant,
                dayOffset: i
            ))
        }
        try await dependencies.transactionRepository.upsert(transactions)

        var query = TransactionQuery()
        query.categoryIDs = CategoryHierarchy().descendantIDs(of: parentA.id, in: try await dependencies.categoryRepository.categories())

        let page = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .merchantAscending, offset: 0, limit: 500
        )
        // Alle ChildA1-Txns (nicht die B1), global merchant-sortiert.
        #expect(page.transactions.allSatisfy { $0.categoryID == childA1.id })
        let merchants = page.transactions.map(\.effectiveMerchantName)
        #expect(merchants == merchants.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }
}