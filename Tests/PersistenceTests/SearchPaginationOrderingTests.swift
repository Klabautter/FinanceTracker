import Foundation
import Testing

@testable import FinanceTracker

/// WP10 (§81-82): Search-Pagination ist GLOBAL sortiert: Seite 1 enthält
/// die global neuesten Treffer, auch wenn der neueste Treffer erst in
/// einem späten ID-Chunk liegt; Annotation-Notizen bleiben im Suchindex
/// aktuell (§80).
@MainActor
@Suite("SearchPaginationOrdering")
struct SearchPaginationOrderingTests {

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func txn(
        accountID: UUID,
        merchant: String,
        minutesOffset: Int,
        tagIDs: [UUID] = []
    ) -> Transaction {
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        var txn = Transaction(
            accountID: accountID,
            source: .manual,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(minutesOffset % 90 + 1), currency: .eur),
            bookedAt: Calendar.current.date(byAdding: .minute, value: minutesOffset, to: base)!,
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
        txn.tagIDs = tagIDs
        return txn
    }

    @Test("Globale Sortierung: global neuester Treffer steht auf Seite 1 ganz oben")
    func globalNewestOnPageOne() async throws {
        let dependencies = try makeDependencies()
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        // 800 Treffer mit streng aufsteigenden Zeitpunkten, der NEUESTE
        // (höchster Zeitstempel) wird zuletzt gespeichert und liegt damit
        // im zuletzt bearbeiteten ID-Chunk.
        var transactions: [Transaction] = []
        for i in 0..<800 {
            transactions.append(txn(accountID: account.id, merchant: "ChunkSuche", minutesOffset: i))
        }
        let newest = txn(accountID: account.id, merchant: "ChunkSuche", minutesOffset: 10_000)
        transactions.append(newest)
        try await dependencies.transactionRepository.upsert(transactions)

        var query = TransactionQuery()
        query.searchText = "chunksuche"

        let page1 = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .dateDescending, offset: 0, limit: 300
        )
        let page2 = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .dateDescending, offset: 300, limit: 300
        )

        #expect(page1.transactions.count == 300)
        #expect(page1.hasMore)
        // Global neuester Treffer = Seite 1, Position 1 (§81).
        #expect(page1.transactions.first?.id == newest.id)

        // Kein Overlap, global absteigend über beide Seiten (§81).
        let ids1 = Set(page1.transactions.map(\.id))
        let ids2 = Set(page2.transactions.map(\.id))
        #expect(ids1.isDisjoint(with: ids2))
        let allDates = (page1.transactions + page2.transactions).map(\.displayDate)
        #expect(allDates == allDates.sorted(by: >))

        // Aufsteigend invers: global ältester Treffer zuerst.
        let ascendingPage1 = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .dateAscending, offset: 0, limit: 300
        )
        #expect(ascendingPage1.transactions.first?.id != newest.id)
        let ascendingDates = ascendingPage1.transactions.map(\.displayDate)
        #expect(ascendingDates == ascendingDates.sorted(by: <))
    }

    @Test("Search + Tag-Kombi bleibt global sortiert und vollständig")
    func searchPlusTag() async throws {
        let dependencies = try makeDependencies()
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let tag = Tag(name: "Urlaub")
        try await dependencies.tagRepository.upsert([tag])

        var transactions: [Transaction] = []
        for i in 0..<350 {
            let tags: [UUID] = i % 2 == 0 ? [tag.id] : []
            transactions.append(txn(
                accountID: account.id,
                merchant: "TagSuche",
                minutesOffset: i,
                tagIDs: tags
            ))
        }
        try await dependencies.transactionRepository.upsert(transactions)

        var query = TransactionQuery()
        query.searchText = "tagsuche"
        query.tagIDs = [tag.id]
        query.tagMatchMode = .any

        let page1 = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .dateDescending, offset: 0, limit: 100
        )
        let page2 = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .dateDescending, offset: 100, limit: 100
        )

        let all = page1.transactions + page2.transactions
        #expect(all.count == 175) // 350/2
        let dates = all.map(\.displayDate)
        #expect(dates == dates.sorted(by: >))
    }

    @Test("Annotation-Note wird im Suchindex aktualisiert (§80)")
    func annotationNoteIndexed() async throws {
        let dependencies = try makeDependencies()
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        let txn = Transaction(
            accountID: account.id,
            source: .manual,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -42, currency: .eur),
            bookedAt: Date(),
            merchantDisplayName: "Bauhaus"
        )
        try await dependencies.transactionRepository.upsert([txn])

        var query = TransactionQuery()
        query.searchText = "kartoffelkeller"
        func searchPage() async throws -> TransactionPage {
            try await dependencies.transactionRepository.transactionPage(
                matching: query, sort: .dateDescending, offset: 0, limit: 100
            )
        }

        // Vor der Annotation: Suche nach der Notiz findet nichts.
        let before = try await searchPage()
        #expect(before.transactions.isEmpty)

        // Notiz über Annotation setzen → Suche muss den Treffer finden.
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(transactionID: txn.id, note: "Kartoffelkeller Rechnung Juni")
        ])
        let after = try await searchPage()
        #expect(after.transactions.count == 1)
        #expect(after.transactions.first?.id == txn.id)

        // Note löschen (Annotation ohne Notiz) → Index verliert den Text.
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(transactionID: txn.id, note: nil)
        ])
        let cleared = try await searchPage()
        #expect(cleared.transactions.isEmpty)
    }
}