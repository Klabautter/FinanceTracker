import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

/// WP18: Transaktions-Suche skalierbar: ID-Phase + Seiten-Hydratation
/// statt vollständiger Domain-Hydratation pro Suche.
@MainActor
@Suite("TransactionSearch50k")
struct TransactionSearch50kTests {

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func txn(
        merchant: String,
        description: String? = nil,
        note: String? = nil
    ) -> Transaction {
        Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .demo,
            externalID: UUID().uuidString,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(string: "9.99")!, currency: .eur),
            bookedAt: Date(),
            rawDescription: description ?? merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant,
            note: note
        )
    }

    private func page(
        _ dependencies: AppDependencies,
        search: String,
        offset: Int = 0,
        limit: Int = 20
    ) async throws -> TransactionPage {
        var query = TransactionQuery()
        query.searchText = search
        return try await dependencies.transactionRepository.transactionPage(
            matching: query,
            sort: .dateDescending,
            offset: offset,
            limit: limit
        )
    }

    @Test("Merchant, Beschreibung und Notiz matchen")
    func fieldMatching() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.transactionRepository.upsert([
            txn(merchant: "SPOTIFY AB"),
            txn(merchant: "REWE", description: "Monats-Einkauf Spotify-Familie"),
            txn(merchant: "REWE", note: "Gutschein von Spotify")
        ])

        let result = try await page(dependencies, search: "spotify")
        #expect(result.transactions.count == 3)
    }

    @Test("Case- und Diakritika-Folding: BÄCKEREI findet bäckerei")
    func folding() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.transactionRepository.upsert([
            txn(merchant: "Bäckerei Müller")
        ])

        #expect(try await page(dependencies, search: "BÄCKEREI").transactions.count == 1)
        // Diakritika-Folding: ä → a (die Umschrift "ae" bleibt eigenständig).
        #expect(try await page(dependencies, search: "backerei").transactions.count == 1)
        #expect(try await page(dependencies, search: "MÜLLER").transactions.count == 1)
    }

    @Test("Kein Treffer → leere Seite")
    func noMatch() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.transactionRepository.upsert([
            txn(merchant: "REWE")
        ])
        let result = try await page(dependencies, search: "xyz-nicht-vorhanden")
        #expect(result.transactions.isEmpty)
        #expect(!result.hasMore)
    }

    @Test("Pagination läuft über die gefilterte Menge korrekt")
    func pagination() async throws {
        let dependencies = try makeDependencies()
        var rows: [Transaction] = []
        for index in 0..<25 {
            rows.append(txn(merchant: "Paginierter Händler \(index)"))
        }
        try await dependencies.transactionRepository.upsert(rows)

        let firstPage = try await page(dependencies, search: "paginierter", offset: 0, limit: 10)
        #expect(firstPage.transactions.count == 10)
        #expect(firstPage.hasMore)

        let secondPage = try await page(dependencies, search: "paginierter", offset: 10, limit: 10)
        #expect(secondPage.transactions.count == 10)
        #expect(secondPage.hasMore)

        let thirdPage = try await page(dependencies, search: "paginierter", offset: 20, limit: 10)
        #expect(thirdPage.transactions.count == 5)
        #expect(!thirdPage.hasMore)

        // Keine Überschneidung zwischen den Seiten.
        let ids = Set(firstPage.transactions.map(\.id) + secondPage.transactions.map(\.id) + thirdPage.transactions.map(\.id))
        #expect(ids.count == 25)
    }

    @Test("Leere Suche → normale Paginierung ohne Suchfilter")
    func emptySearch() async throws {
        let dependencies = try makeDependencies()
        var rows: [Transaction] = []
        for _ in 0..<15 {
            rows.append(txn(merchant: "Händler"))
        }
        try await dependencies.transactionRepository.upsert(rows)

        let result = try await page(dependencies, search: "", offset: 0, limit: 10)
        #expect(result.transactions.count == 10)
        #expect(result.hasMore)
    }

    @Test("Suche über 5.000 Rows bleibt schnell (ID-Phase, keine Full-Hydratation)")
    func performanceSmoke() async throws {
        let dependencies = try makeDependencies()
        var rows: [Transaction] = []
        rows.reserveCapacity(5_000)
        for index in 0..<5_000 {
            rows.append(txn(merchant: "Händler \(index) [\(index % 17)]"))
        }
        try await dependencies.transactionRepository.upsert(rows)

        let start = Date()
        let result = try await page(dependencies, search: "händler 499", limit: 20)
        let duration = Date().timeIntervalSince(start)

        #expect(!result.transactions.isEmpty)
        #expect(duration < 2.0, "Suche über 5k Rows dauerte \(duration)s")
    }
}
