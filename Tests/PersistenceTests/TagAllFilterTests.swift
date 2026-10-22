import Foundation
import Testing

@testable import FinanceTracker

/// WP9 (§74-75): Tag-ALL ist global korrekt über die GESAMTE Datenmenge
/// kein 10-Seiten-Cap als Datenkorrektheit, Treffer außerhalb geladener
/// Seiten werden gefunden.
@MainActor
@Suite("TagAllFilter")
struct TagAllFilterTests {

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func txn(
        accountID: UUID,
        merchant: String,
        dayOffset: Int,
        tagIDs: [UUID] = [],
        categoryID: UUID? = nil
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
        txn.tagIDs = tagIDs
        txn.categoryID = categoryID
        return txn
    }

    @Test("ALL über 600 Txns: Treffer am Anfang und bei Txn 4000+ auf Seite 1, global vollständig")
    func tagAllBeyondPaginationBoundary() async throws {
        let dependencies = try makeDependencies()

        let t1 = Tag(name: "Urlaub")
        let t2 = Tag(name: "Dienstlich")
        try await dependencies.tagRepository.upsert([t1, t2])

        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        // 600 Txns; ALL(T1,T2)-Treffer: 4 Stück, bei Index 1 (frisch),
        // 250, 450 (weit außerhalb klassischer Frühpaging-Bereiche) und 599 (am Ende).
        var transactions: [Transaction] = []
        let matchedIndexes: Set<Int> = [1, 250, 450, 599]
        for i in 0..<600 {
            let tags: [UUID] = matchedIndexes.contains(i) ? [t1.id, t2.id] : (i % 3 == 0 ? [t1.id] : [])
            transactions.append(txn(
                accountID: account.id,
                merchant: "Händler \(i)",
                dayOffset: i,
                tagIDs: tags
            ))
        }
        try await dependencies.transactionRepository.upsert(transactions)

        var query = TransactionQuery()
        query.tagIDs = [t1.id, t2.id]
        query.tagMatchMode = .all

        let page = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .dateDescending, offset: 0, limit: 300
        )
        // Alle 4 Treffer sind auf SEITE 1, auch der am Ende der Historie.
        #expect(page.transactions.count == 4)
        #expect(!page.hasMore)
        let dates = page.transactions.map(\.displayDate)
        #expect(dates == dates.sorted(by: >))
        // Kein Nicht-Treffer in der Seite.
        #expect(page.transactions.allSatisfy { txn in
            Set(txn.tagIDs ?? []).isSuperset(of: [t1.id, t2.id])
        })
    }

    @Test("ANY vs ALL: ANY liefert Obermenge, ALL schneidet auf ID-Ebene")
    func anyVsAll() async throws {
        let dependencies = try makeDependencies()

        let t1 = Tag(name: "A")
        let t2 = Tag(name: "B")
        try await dependencies.tagRepository.upsert([t1, t2])

        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        try await dependencies.transactionRepository.upsert([
            txn(accountID: account.id, merchant: "Nur A", dayOffset: 1, tagIDs: [t1.id]),
            txn(accountID: account.id, merchant: "Nur A 2", dayOffset: 2, tagIDs: [t1.id]),
            txn(accountID: account.id, merchant: "Beide", dayOffset: 3, tagIDs: [t1.id, t2.id]),
            txn(accountID: account.id, merchant: "Beide 2", dayOffset: 4, tagIDs: [t1.id, t2.id]),
            txn(accountID: account.id, merchant: "Ohne", dayOffset: 5)
        ])

        var anyQuery = TransactionQuery()
        anyQuery.tagIDs = [t1.id, t2.id]
        anyQuery.tagMatchMode = .any
        let anyResults = try await dependencies.transactionRepository.transactions(matching: anyQuery)
        #expect(anyResults.count == 4)

        var allQuery = TransactionQuery()
        allQuery.tagIDs = [t1.id, t2.id]
        allQuery.tagMatchMode = .all
        let allResults = try await dependencies.transactionRepository.transactions(matching: allQuery)
        #expect(allResults.count == 2)
        #expect(allResults.allSatisfy { Set($0.tagIDs ?? []).isSuperset(of: [t1.id, t2.id]) })
    }

    @Test("Drei Tags: nur Txns mit allen dreien")
    func threeTagsAll() async throws {
        let dependencies = try makeDependencies()

        let t1 = Tag(name: "A")
        let t2 = Tag(name: "B")
        let t3 = Tag(name: "C")
        try await dependencies.tagRepository.upsert([t1, t2, t3])

        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        try await dependencies.transactionRepository.upsert([
            txn(accountID: account.id, merchant: "AB", dayOffset: 1, tagIDs: [t1.id, t2.id]),
            txn(accountID: account.id, merchant: "ABC", dayOffset: 2, tagIDs: [t1.id, t2.id, t3.id]),
            txn(accountID: account.id, merchant: "BC", dayOffset: 3, tagIDs: [t2.id, t3.id])
        ])

        var query = TransactionQuery()
        query.tagIDs = [t1.id, t2.id, t3.id]
        query.tagMatchMode = .all
        let results = try await dependencies.transactionRepository.transactions(matching: query)
        #expect(results.count == 1)
        #expect(results.first?.effectiveMerchantName == "ABC")
    }

    @Test("Search + ALL und Category + ALL kombinieren korrekt")
    func combinationsWithAll() async throws {
        let dependencies = try makeDependencies()

        let t1 = Tag(name: "A")
        let t2 = Tag(name: "B")
        try await dependencies.tagRepository.upsert([t1, t2])

        let catX = FinanceTracker.Category(name: "X", systemIconName: "tag")
        try await dependencies.categoryRepository.upsert([catX])

        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        try await dependencies.transactionRepository.upsert([
            txn(accountID: account.id, merchant: "Sonderhaus", dayOffset: 1, tagIDs: [t1.id, t2.id], categoryID: catX.id),
            txn(accountID: account.id, merchant: "Sonderhaus", dayOffset: 2, tagIDs: [t1.id, t2.id]),
            txn(accountID: account.id, merchant: "Anderes", dayOffset: 3, tagIDs: [t1.id, t2.id], categoryID: catX.id)
        ])

        // Search + ALL
        var searchAll = TransactionQuery()
        searchAll.tagIDs = [t1.id, t2.id]
        searchAll.tagMatchMode = .all
        searchAll.searchText = "sonderhaus"
        let searchResults = try await dependencies.transactionRepository.transactions(matching: searchAll)
        #expect(searchResults.count == 2)

        // Category + ALL: beide Treffer haben Kategorie X UND beide Tags
        // (#1 „Sonderhaus" + #3 „Anderes"); #2 (Sonderhaus, beide Tags,
        // ohne Kategorie) fällt durch den Category-Filter.
        var categoryAll = TransactionQuery()
        categoryAll.tagIDs = [t1.id, t2.id]
        categoryAll.tagMatchMode = .all
        categoryAll.categoryIDs = [catX.id]
        let categoryResults = try await dependencies.transactionRepository.transactions(matching: categoryAll)
        #expect(categoryResults.count == 2)
        #expect(categoryResults.allSatisfy { $0.categoryID == catX.id })
        #expect(Set(categoryResults.map(\.effectiveMerchantName)) == Set(["Sonderhaus", "Anderes"]))
    }

    @Test("Sort + ALL: Merchant-Sortierung global korrekt über die Treffermenge")
    func sortPlusAll() async throws {
        let dependencies = try makeDependencies()

        let t1 = Tag(name: "A")
        let t2 = Tag(name: "B")
        try await dependencies.tagRepository.upsert([t1, t2])

        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        var transactions: [Transaction] = []
        for i in 0..<50 {
            let merchant = i % 2 == 0 ? "Alpha Markt" : "Zeta Markt"
            transactions.append(txn(
                accountID: account.id,
                merchant: merchant,
                dayOffset: i,
                tagIDs: [t1.id, t2.id]
            ))
        }
        try await dependencies.transactionRepository.upsert(transactions)

        var query = TransactionQuery()
        query.tagIDs = [t1.id, t2.id]
        query.tagMatchMode = .all
        let page = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .merchantAscending, offset: 0, limit: 300
        )
        #expect(page.transactions.count == 50)
        let merchants = page.transactions.map(\.effectiveMerchantName)
        #expect(merchants == merchants.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test("Model-Level: ALL-Filter liefert vollständige Treffer ohne Client-Cap (§73)")
    func modelLevelAllFilterComplete() async throws {
        let dependencies = try makeDependencies()

        let t1 = Tag(name: "Urlaub")
        let t2 = Tag(name: "Dienstlich")
        try await dependencies.tagRepository.upsert([t1, t2])

        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        var transactions: [Transaction] = []
        let matchedIndexes: Set<Int> = [5, 400, 599]
        for i in 0..<600 {
            let tags: [UUID] = matchedIndexes.contains(i) ? [t1.id, t2.id] : []
            transactions.append(txn(accountID: account.id, merchant: "Händler \(i)", dayOffset: i, tagIDs: tags))
        }
        try await dependencies.transactionRepository.upsert(transactions)

        let model = TransactionsModel(dependencies: dependencies)
        model.filterTagIDs = [t1.id, t2.id]
        model.tagFilterMode = .all
        await model.refresh()

        // Alle 3 Treffer sind direkt sichtbar, auch die, die unter dem
        // alten Best-Effort-Cap außerhalb geladener Seiten lagen.
        #expect(model.visibleTransactions.count == 3)
        #expect(model.canLoadMore == false)
    }
}