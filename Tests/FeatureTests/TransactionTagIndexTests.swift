import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

/// WP19: Tags als normalisierte, querybare Relation (V8).
@MainActor
@Suite("TransactionTagIndex")
struct TransactionTagIndexTests {

    private func makeDependencies() throws -> (AppDependencies, ModelContainer) {
        let store = try SwiftDataStore(inMemory: true)
        return (AppDependencies.make(container: store.container, baseCurrency: .eur), store.container)
    }

    private func makeTxn(
        accountID: UUID,
        merchant: String,
        tagIDs: [UUID] = [],
        index: Int = 0
    ) -> Transaction {
        Transaction(
            id: UUID(),
            accountID: accountID,
            source: .demo,
            externalID: "tag-\(index)-\(UUID().uuidString)",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(index + 1), currency: .eur),
            bookedAt: Date().addingTimeInterval(TimeInterval(-3600 * index)),
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant,
            tagIDs: tagIDs
        )
    }

    @Test("Write-through: Upsert mit tagIDs erzeugt Join-Rows; Usage-Counts stimmen")
    func writeThroughAndCounts() async throws {
        let (dependencies, _) = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let urlaub = UUID()
        let italien = UUID()
        try await dependencies.tagRepository.upsert([
            Tag(id: urlaub, name: "Urlaub 2026", colorToken: .blue),
            Tag(id: italien, name: "Italien", colorToken: .teal)
        ])

        try await dependencies.transactionRepository.upsert([
            makeTxn(accountID: account.id, merchant: "Hotel", tagIDs: [urlaub, italien], index: 0),
            makeTxn(accountID: account.id, merchant: "Strand", tagIDs: [urlaub], index: 1),
            makeTxn(accountID: account.id, merchant: "Office", index: 2)
        ])

        let counts = try await dependencies.tagRepository.usageCounts()
        #expect(counts[urlaub] == 2)
        #expect(counts[italien] == 1)
    }

    @Test("ANY-Tag-Filter findet Treffer weit über die erste Seite hinaus (kein Cap)")
    func filterBeyondFirstPage() async throws {
        let (dependencies, _) = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let targetTag = UUID()
        let otherTag = UUID()
        try await dependencies.tagRepository.upsert([
            Tag(id: targetTag, name: "Gesucht", colorToken: .blue),
            Tag(id: otherTag, name: "Anders", colorToken: .teal)
        ])

        // 900 Rows: Nur jede zweite trägt den Gesucht-Tag. Die Treffer liegen
        // über die erste Seite (300) hinaus, der Pushdown liefert sie
        // vollständig, ohne willkürliche Nachlade-Caps.
        var rows: [Transaction] = []
        for index in 0..<900 {
            let tags = index % 2 == 0 ? [targetTag] : [otherTag]
            rows.append(makeTxn(accountID: account.id, merchant: "Händler \(index)", tagIDs: tags, index: index))
        }
        try await dependencies.transactionRepository.upsert(rows)

        var query = TransactionQuery()
        query.tagIDs = [targetTag]
        let page = try await dependencies.transactionRepository.transactionPage(
            matching: query,
            sort: .dateAscending,
            offset: 0,
            limit: 1000
        )
        #expect(page.transactions.count == 450)
        #expect(page.transactions.allSatisfy { ($0.tagIDs ?? []).contains(targetTag) })
        #expect(!page.hasMore)

        // Paginiert: zweite Seite über den gefilterten Treffern.
        let secondPage = try await dependencies.transactionRepository.transactionPage(
            matching: query,
            sort: .dateAscending,
            offset: 400,
            limit: 100
        )
        #expect(secondPage.transactions.count == 50)
        let firstIDs = Set(page.transactions.prefix(400).map(\.id))
        #expect(firstIDs.isDisjoint(with: Set(secondPage.transactions.map(\.id))))
    }

    @Test("Tag-Delete: Join-Rows weg, Transaktionen bleiben, Counts aktualisiert")
    func tagDeleteRemovesLinks() async throws {
        let (dependencies, _) = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let doomedTag = UUID()
        try await dependencies.tagRepository.upsert([
            Tag(id: doomedTag, name: "Weg damit", colorToken: .red)
        ])

        let txnA = makeTxn(accountID: account.id, merchant: "A", tagIDs: [doomedTag], index: 0)
        let txnB = makeTxn(accountID: account.id, merchant: "B", tagIDs: [], index: 1)
        try await dependencies.transactionRepository.upsert([txnA, txnB])

        #expect(try await dependencies.tagRepository.usageCounts()[doomedTag] == 1)

        try await dependencies.tagRepository.delete(id: doomedTag)

        // Counts weg, Transaktionen bleiben.
        let counts = try await dependencies.tagRepository.usageCounts()
        #expect(counts[doomedTag] == nil)
        let remaining = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(remaining.count == 2)
    }

    @Test("Backfill: Bestands-tagIDsJSON ohne Rows wird beim ersten Query zurückgefüllt")
    func backfillPreservesTagLinks() async throws {
        let (dependencies, container) = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let legacyTag = UUID()
        try await dependencies.tagRepository.upsert([
            Tag(id: legacyTag, name: "Legacy", colorToken: .blue)
        ])

        // Transaktion MIT tagIDs schreiben, dann die Join-Rows künstlich
        // leeren (simuliert V7-Bestand vor dem Backfill).
        let legacy = makeTxn(accountID: account.id, merchant: "Legacy-Txn", tagIDs: [legacyTag], index: 0)
        try await dependencies.transactionRepository.upsert([legacy])

        // Rows entfernen, ohne den JSON-Stand anzutasten (V7-Bestand simulieren).
        let context = ModelContext(container)
        try context.delete(model: SDTransactionTagEntity.self)
        try context.save()

        // Erster Tag-Query → Backfill → die Legacy-Verknüpfung ist da.
        let counts = try await dependencies.tagRepository.usageCounts()
        #expect(counts[legacyTag] == 1)

        var query = TransactionQuery()
        query.tagIDs = [legacyTag]
        let page = try await dependencies.transactionRepository.transactionPage(
            matching: query,
            sort: .dateDescending,
            offset: 0,
            limit: 10
        )
        #expect(page.transactions.count == 1)
        #expect(page.transactions.first?.id == legacy.id)
    }
}

/// WP19: V7-Store migriert zu V8, die Tag-Join-Tabelle entsteht und die
/// bestehenden JSON-Tag-Links werden beim ersten Query zurückgefüllt.
@MainActor
@Suite("TagSchemaMigration")
struct TagSchemaMigrationTests {

    @Test("V7-Store wird zu V8 migriert (Tag-Join-Tabelle entsteht)")
    func migrationV7ToV8() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tag-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("migration.store")
        defer { try? FileManager.default.removeItem(at: directory) }

        // V7-Store erzeugen (eine Annotation mit tagIDs, wie im bewährten Muster).
        do {
            let configuration = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(
                for: Schema(versionedSchema: FinanceTrackerSchemaV7.self),
                configurations: [configuration]
            )
            let context = ModelContext(container)
            let tagJSON = try JSONEncoder().encode([UUID()])
            context.insert(SDTransactionAnnotationEntity(
                id: UUID(),
                transactionID: UUID(),
                note: nil,
                reviewed: false,
                excludedFromAnalytics: false,
                manualKindOverrideRaw: nil,
                tagIDsJSON: tagJSON,
                createdAt: Date(),
                updatedAt: Date()
            ))
            try context.save()
        }

        // V8 öffnen (Migration läuft), Join-Tabelle ist leer aber ansprechbar.
        let migrated = try SwiftDataStore(url: storeURL)
        let context = ModelContext(migrated.container)
        let rows = try context.fetch(FetchDescriptor<SDTransactionTagEntity>())
        #expect(rows.isEmpty) // Backfill passiert on first use im ModelActor
    }
}
