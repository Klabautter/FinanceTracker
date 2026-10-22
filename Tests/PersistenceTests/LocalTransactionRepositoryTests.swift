import Foundation
import Testing

@testable import FinanceTracker

@Suite("LocalTransactionRepository")
struct LocalTransactionRepositoryTests {
    private func makeStore() throws -> (SwiftDataStore, AppDependencies) {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        return (store, dependencies)
    }

    private func makeTransaction(
        amount: Decimal = -10,
        bookedAt: Date? = Date(timeIntervalSince1970: 1_750_000_000),
        merchant: String = "REWE",
        categoryID: UUID? = nil
    ) -> Transaction {
        Transaction(
            accountID: UUID(),
            source: .demo,
            externalID: "ext-1",
            amount: Money(amount: amount, currency: .eur),
            bookedAt: bookedAt,
            rawMerchantName: merchant,
            categoryID: categoryID
        )
    }

    @Test("Upsert mit gleicher ID erzeugt keinen Datensatz doppelt")
    func upsertDeduplicatesByID() async throws {
        let (_, dependencies) = try makeStore()
        let txn = makeTransaction()

        try await dependencies.transactionRepository.upsert([txn])
        try await dependencies.transactionRepository.upsert([txn])

        #expect(try await dependencies.transactionRepository.count() == 1)
    }

    @Test("Update über Upsert ändert Betrag")
    func upsertUpdatesFields() async throws {
        let (_, dependencies) = try makeStore()
        var txn = makeTransaction(amount: -10)
        try await dependencies.transactionRepository.upsert([txn])

        txn.amount = Money(amount: -99, currency: .eur)
        try await dependencies.transactionRepository.upsert([txn])

        let loaded = try await dependencies.transactionRepository.transaction(id: txn.id)
        #expect(loaded?.amount.amount == -99)
        #expect(try await dependencies.transactionRepository.count() == 1)
    }

    @Test("Bulk-Upsert hält vorgewärmten Such- und Tag-Index sofort konsistent")
    func bulkUpsertWritesThroughSearchAndTags() async throws {
        let (_, dependencies) = try makeStore()
        let accountID = UUID()
        let initialTagID = UUID()
        let replacementTagID = UUID()

        // Beide einmaligen Backfills laufen vor dem Schreiben. Treffer danach
        // können daher nur aus dem Write-through des Upserts stammen.
        let emptySearchPage = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "vorwaermen"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(emptySearchPage.transactions.isEmpty)
        var emptyTagQuery = TransactionQuery()
        emptyTagQuery.tagIDs = [initialTagID]
        let emptyTagPage = try await dependencies.transactionRepository.transactionPage(
            matching: emptyTagQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(emptyTagPage.transactions.isEmpty)

        var first = Transaction(
            accountID: accountID,
            source: .manual,
            externalID: "bulk-index-1",
            amount: Money(amount: -12, currency: .eur),
            bookedAt: Date(timeIntervalSince1970: 1_750_000_000),
            rawMerchantName: "Alte Suchnadel",
            tagIDs: [initialTagID]
        )
        let second = Transaction(
            accountID: accountID,
            source: .manual,
            externalID: "bulk-index-2",
            amount: Money(amount: -24, currency: .eur),
            bookedAt: Date(timeIntervalSince1970: 1_750_000_100),
            rawMerchantName: "Zweite Bulkzeile",
            tagIDs: [initialTagID, replacementTagID]
        )
        try await dependencies.transactionRepository.upsert([first, second])

        let initialSearchPage = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "alte suchnadel"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(initialSearchPage.transactions.map(\.id) == [first.id])

        first.rawMerchantName = "Neue Suchnadel"
        first.tagIDs = [replacementTagID]
        try await dependencies.transactionRepository.upsert([first])

        let oldSearchPage = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "alte suchnadel"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        let newSearchPage = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "neue suchnadel"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(oldSearchPage.transactions.isEmpty)
        #expect(newSearchPage.transactions.map(\.id) == [first.id])

        var initialTagQuery = TransactionQuery()
        initialTagQuery.tagIDs = [initialTagID]
        let initialTagPage = try await dependencies.transactionRepository.transactionPage(
            matching: initialTagQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(initialTagPage.transactions.map(\.id) == [second.id])

        var replacementTagQuery = TransactionQuery()
        replacementTagQuery.tagIDs = [replacementTagID]
        let replacementTagPage = try await dependencies.transactionRepository.transactionPage(
            matching: replacementTagQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(Set(replacementTagPage.transactions.map(\.id)) == [first.id, second.id])
    }

    @Test("Import ist nach bereits verwendeter Suche und Tag-Abfrage sofort indexiert")
    func importCommitWritesThroughPrewarmedIndexes() async throws {
        let (_, dependencies) = try makeStore()
        let tagID = UUID()

        // Regression: Diese Abfragen schließen die Einmal-Backfills. Der
        // anschließende Import muss seine Indexzeilen daher selbst committen.
        _ = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "noch nicht importiert"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        var tagQuery = TransactionQuery()
        tagQuery.tagIDs = [tagID]
        _ = try await dependencies.transactionRepository.transactionPage(
            matching: tagQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )

        let batch = ImportBatch(
            providerIdentifier: "index-regression",
            sourceRaw: TransactionSource.genericCSV.rawValue,
            fileName: "index-regression.csv",
            fileHashSHA256: ImportBatch.fileHash(of: Data("index-regression".utf8)),
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            completedAt: Date(timeIntervalSince1970: 1_750_000_001),
            totalRows: 1,
            importedCount: 1,
            updatedCount: 0,
            duplicateCount: 0,
            failedCount: 0
        )
        let imported = Transaction(
            accountID: UUID(),
            source: .genericCSV,
            externalID: "import-index-1",
            amount: Money(amount: -42, currency: .eur),
            bookedAt: Date(timeIntervalSince1970: 1_750_000_000),
            rawMerchantName: "Café Aurora Nachimport",
            tagIDs: [tagID],
            importBatchID: batch.id
        )

        try await dependencies.importBatchRepository.commitImport(
            batch: batch,
            inserts: [imported],
            updates: []
        )

        let searchPage = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "cafe aurora"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(searchPage.transactions.map(\.id) == [imported.id])

        let tagPage = try await dependencies.transactionRepository.transactionPage(
            matching: tagQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(tagPage.transactions.map(\.id) == [imported.id])
        #expect(try await dependencies.importBatchRepository.batch(id: batch.id) == batch)
    }

    @Test("Annotation-Tags steuern ANY und ALL und Entfernung stellt Transaktions-Tags wieder her")
    func annotationTagsDriveDerivedIndex() async throws {
        let (_, dependencies) = try makeStore()
        let providerTagID = UUID()
        let userTagA = UUID()
        let userTagB = UUID()
        let transaction = Transaction(
            accountID: UUID(),
            source: .openBanking,
            externalID: "annotation-index",
            amount: Money(amount: -18, currency: .eur),
            bookedAt: Date(timeIntervalSince1970: 1_750_000_000),
            rawMerchantName: "Annotation Index",
            note: "Provider-Notiz",
            tagIDs: [providerTagID]
        )
        try await dependencies.transactionRepository.upsert([transaction])

        // Backfill vor der Annotation schließen; die folgenden Links müssen
        // durch den Annotation-Write-through entstehen.
        var warmup = TransactionQuery()
        warmup.tagIDs = [userTagA]
        _ = try await dependencies.transactionRepository.transactionPage(
            matching: warmup,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )

        var annotation = TransactionAnnotation(
            transactionID: transaction.id,
            note: "Steuerbeleg prüfen",
            tagIDs: [userTagA, userTagB]
        )
        try await dependencies.transactionAnnotationRepository.upsert([annotation])

        var anyQuery = TransactionQuery()
        anyQuery.tagIDs = [userTagA, UUID()]
        anyQuery.tagMatchMode = .any
        let anyPage = try await dependencies.transactionRepository.transactionPage(
            matching: anyQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(anyPage.transactions.map(\.id) == [transaction.id])

        var allQuery = TransactionQuery()
        allQuery.tagIDs = [userTagA, userTagB]
        allQuery.tagMatchMode = .all
        let allPage = try await dependencies.transactionRepository.transactionPage(
            matching: allQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(allPage.transactions.map(\.id) == [transaction.id])

        var providerTagQuery = TransactionQuery()
        providerTagQuery.tagIDs = [providerTagID]
        let hiddenProviderTagPage = try await dependencies.transactionRepository.transactionPage(
            matching: providerTagQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(hiddenProviderTagPage.transactions.isEmpty)

        let notePage = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "steuerbeleg"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(notePage.transactions.map(\.id) == [transaction.id])

        annotation.tagIDs = []
        try await dependencies.transactionAnnotationRepository.upsert([annotation])
        let clearedUserTagPage = try await dependencies.transactionRepository.transactionPage(
            matching: allQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        let stillHiddenProviderTagPage = try await dependencies.transactionRepository.transactionPage(
            matching: providerTagQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(clearedUserTagPage.transactions.isEmpty)
        #expect(stillHiddenProviderTagPage.transactions.isEmpty)

        try await dependencies.transactionAnnotationRepository.delete(transactionID: transaction.id)

        let removedUserTagPage = try await dependencies.transactionRepository.transactionPage(
            matching: allQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        let restoredProviderTagPage = try await dependencies.transactionRepository.transactionPage(
            matching: providerTagQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(removedUserTagPage.transactions.isEmpty)
        #expect(restoredProviderTagPage.transactions.map(\.id) == [transaction.id])
    }

    @Test("Import respektiert bereits vorhandene Annotation in Such- und Tag-Index")
    func importPreservesExistingAnnotationIndexes() async throws {
        let (_, dependencies) = try makeStore()
        let transactionID = UUID()
        let providerTagID = UUID()
        let userTagID = UUID()
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(
                transactionID: transactionID,
                note: "Persönliche Reisekosten-Notiz",
                tagIDs: [userTagID]
            )
        ])

        let batch = ImportBatch(
            providerIdentifier: "annotation-import",
            sourceRaw: TransactionSource.openBanking.rawValue,
            fileName: nil,
            fileHashSHA256: "annotation-import",
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            completedAt: Date(timeIntervalSince1970: 1_750_000_001),
            totalRows: 1,
            importedCount: 1,
            updatedCount: 0,
            duplicateCount: 0,
            failedCount: 0
        )
        let imported = Transaction(
            id: transactionID,
            accountID: UUID(),
            source: .openBanking,
            externalID: "annotation-import-1",
            amount: Money(amount: -87, currency: .eur),
            bookedAt: Date(timeIntervalSince1970: 1_750_000_000),
            rawMerchantName: "Hotel Provider",
            note: "Provider-Notiz",
            tagIDs: [providerTagID],
            importBatchID: batch.id
        )
        try await dependencies.importBatchRepository.commitImport(
            batch: batch,
            inserts: [imported],
            updates: []
        )

        let notePage = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "personliche reisekosten"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(notePage.transactions.map(\.id) == [transactionID])

        var userTagQuery = TransactionQuery()
        userTagQuery.tagIDs = [userTagID]
        var providerTagQuery = TransactionQuery()
        providerTagQuery.tagIDs = [providerTagID]
        let userTagPage = try await dependencies.transactionRepository.transactionPage(
            matching: userTagQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        let providerTagPage = try await dependencies.transactionRepository.transactionPage(
            matching: providerTagQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(userTagPage.transactions.map(\.id) == [transactionID])
        #expect(providerTagPage.transactions.isEmpty)
    }

    @Test("Import-Rollback entfernt und restauriert abgeleitete Indizes")
    func importRollbackRepairsDerivedIndexes() async throws {
        let (_, dependencies) = try makeStore()
        let originalTagID = UUID()
        let changedTagID = UUID()
        var original = Transaction(
            accountID: UUID(),
            source: .genericCSV,
            externalID: "rollback-update",
            amount: Money(amount: -11, currency: .eur),
            bookedAt: Date(timeIntervalSince1970: 1_750_000_000),
            rawMerchantName: "Ursprünglicher Händler",
            tagIDs: [originalTagID]
        )
        try await dependencies.transactionRepository.upsert([original])
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(transactionID: original.id, tagIDs: [originalTagID])
        ])

        let batchID = UUID()
        let inserted = Transaction(
            accountID: UUID(),
            source: .genericCSV,
            externalID: "rollback-insert",
            amount: Money(amount: -22, currency: .eur),
            bookedAt: Date(timeIntervalSince1970: 1_750_000_100),
            rawMerchantName: "Später gelöschter Import",
            tagIDs: [changedTagID],
            importBatchID: batchID
        )
        let previousSnapshot = TransactionSnapshot(transaction: original)
        original.rawMerchantName = "Geänderter Händler"
        original.tagIDs = [changedTagID]
        original.importBatchID = batchID
        let batch = ImportBatch(
            id: batchID,
            providerIdentifier: "rollback-index",
            sourceRaw: TransactionSource.genericCSV.rawValue,
            fileName: "rollback.csv",
            fileHashSHA256: "rollback-index",
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            completedAt: Date(timeIntervalSince1970: 1_750_000_001),
            totalRows: 2,
            importedCount: 1,
            updatedCount: 1,
            duplicateCount: 0,
            failedCount: 0,
            mutations: [
                ImportMutation(transactionID: inserted.id, kind: .inserted, previousSnapshot: nil),
                ImportMutation(transactionID: original.id, kind: .updated, previousSnapshot: previousSnapshot)
            ]
        )
        try await dependencies.importBatchRepository.commitImport(
            batch: batch,
            inserts: [inserted],
            updates: [original]
        )
        try await dependencies.importBatchRepository.rollbackImportBatch(id: batch.id)

        let originalPage = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "ursprunglicher handler"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        let changedPage = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "geanderter handler"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        let insertedPage = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "spater geloschter import"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(originalPage.transactions.map(\.id) == [original.id])
        #expect(changedPage.transactions.isEmpty)
        #expect(insertedPage.transactions.isEmpty)

        var originalTagQuery = TransactionQuery()
        originalTagQuery.tagIDs = [originalTagID]
        var changedTagQuery = TransactionQuery()
        changedTagQuery.tagIDs = [changedTagID]
        let originalTagPage = try await dependencies.transactionRepository.transactionPage(
            matching: originalTagQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        let changedTagPage = try await dependencies.transactionRepository.transactionPage(
            matching: changedTagQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(originalTagPage.transactions.map(\.id) == [original.id])
        #expect(changedTagPage.transactions.isEmpty)
    }

    @Test("Mapper-Roundtrip erhält alle Felder inklusive Krypto-Metadaten")
    func roundtripPreservesFields() async throws {
        let (_, dependencies) = try makeStore()
        let categoryID = UUID()
        let txn = Transaction(
            accountID: UUID(),
            source: .metamaskCardCSV,
            externalID: "mm-42",
            sourceFingerprint: "abc123",
            status: .pending,
            amount: Money(amount: Decimal(string: "-5.40")!, currency: .eur),
            authorizedAt: Date(timeIntervalSince1970: 1_750_100_000),
            rawDescription: "COFFEE SHOP 0x12",
            rawMerchantName: "COFFEE SHOP",
            merchantDisplayName: "Coffee Shop",
            categoryID: categoryID,
            paymentMethod: .crypto,
            originalCurrency: .eur,
            originalAmount: Decimal(string: "-5.40")!,
            cryptoAsset: "USDC",
            cryptoAmount: Decimal(string: "5.40")!,
            cashbackAmount: Decimal(string: "0.16")!,
            cashbackCurrency: .eur
        )

        try await dependencies.transactionRepository.upsert([txn])
        let loaded = try await dependencies.transactionRepository.transaction(id: txn.id)

        #expect(loaded != nil)
        #expect(loaded == txn)
        #expect(loaded?.cryptoAsset == "USDC")
        #expect(loaded?.categoryID == categoryID)
        #expect(loaded?.paymentMethod == .crypto)
        #expect(loaded?.cashbackAmount == Decimal(string: "0.16")!)
        #expect(loaded?.cashbackCurrency == .eur)
    }

    @Test("Query filtert, sortiert und begrenzt")
    func queryFiltersSortsAndLimits() async throws {
        let (_, dependencies) = try makeStore()

        func txn(daysAgo: Int, amount: Decimal) -> Transaction {
            Transaction(
                accountID: UUID(),
                source: .demo,
                amount: Money(amount: amount, currency: .eur),
                bookedAt: Date(timeIntervalSince1970: TimeInterval(1_750_000_000 - daysAgo * 86_400)),
                rawMerchantName: "MERCHANT"
            )
        }

        try await dependencies.transactionRepository.upsert([
            txn(daysAgo: 10, amount: -5),
            txn(daysAgo: 2, amount: -50),
            txn(daysAgo: 5, amount: -25)
        ])

        var query = TransactionQuery()
        query.limit = 2
        let newestFirst = try await dependencies.transactionRepository.transactions(matching: query)

        #expect(newestFirst.count == 2)
        #expect(newestFirst.first?.amount.amount == -50)

        query.sort = .amountAscending
        query.limit = nil
        let cheapestFirst = try await dependencies.transactionRepository.transactions(matching: query)
        #expect(cheapestFirst.first?.amount.amount == -50)
        #expect(cheapestFirst.last?.amount.amount == -5)
    }

    @Test("Datumsintervall schließt das Ende auch im Store-Paging aus")
    func dateIntervalIsHalfOpenInStoreQueries() async throws {
        let (_, dependencies) = try makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = Date(timeIntervalSince1970: 1_800_086_400)
        let atStart = makeTransaction(bookedAt: start)
        let beforeEnd = makeTransaction(bookedAt: end.addingTimeInterval(-0.001))
        let atEnd = makeTransaction(bookedAt: end)
        try await dependencies.transactionRepository.upsert([atStart, beforeEnd, atEnd])

        var query = TransactionQuery()
        query.dateInterval = DateInterval(start: start, end: end)
        query.sort = .dateAscending
        let matching = try await dependencies.transactionRepository.transactions(matching: query)
        let page = try await dependencies.transactionRepository.transactionPage(
            matching: query,
            sort: .dateAscending,
            offset: 0,
            limit: 20
        )

        #expect(Set(matching.map(\.id)) == Set([atStart.id, beforeEnd.id]))
        #expect(Set(page.transactions.map(\.id)) == Set([atStart.id, beforeEnd.id]))
        #expect(!page.hasMore)
    }

    @Test("deleteAll entfernt alle Transaktionen")
    func deleteAll() async throws {
        let (_, dependencies) = try makeStore()
        try await dependencies.transactionRepository.upsert([
            makeTransaction(),
            makeTransaction(),
            makeTransaction()
        ])
        #expect(try await dependencies.transactionRepository.count() == 3)

        try await dependencies.transactionRepository.deleteAll()
        #expect(try await dependencies.transactionRepository.count() == 0)
    }

    @Test("Demo-Löschung erhält Suchindex echter Transaktionen")
    func deleteDemoTransactionsKeepsRealSearchIndex() async throws {
        let (_, dependencies) = try makeStore()
        let real = Transaction(
            accountID: UUID(),
            source: .manual,
            amount: Money(amount: -9, currency: .eur),
            bookedAt: Date(timeIntervalSince1970: 1_750_000_000),
            rawMerchantName: "Echter Suchtreffer"
        )
        let demo = Transaction(
            accountID: UUID(),
            source: .demo,
            amount: Money(amount: -5, currency: .eur),
            bookedAt: Date(timeIntervalSince1970: 1_750_000_100),
            rawMerchantName: "Demo Suchtreffer"
        )
        try await dependencies.transactionRepository.upsert([real, demo])

        // Such-Backfill vor der selektiven Löschung schließen.
        _ = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "echter suchtreffer"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        try await dependencies.transactionRepository.deleteAllDemoTransactions()

        let realPage = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "echter suchtreffer"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        let demoPage = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(searchText: "demo suchtreffer"),
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )
        #expect(realPage.transactions.map(\.id) == [real.id])
        #expect(demoPage.transactions.isEmpty)
    }

    @Test("Paging pusht Konto- und Quellenfilter auch im Suchpfad in den Store")
    func pageFiltersAccountsAndSources() async throws {
        let (_, dependencies) = try makeStore()
        let accountA = UUID()
        let accountB = UUID()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let matching = Transaction(
            accountID: accountA,
            source: .manual,
            amount: Money(amount: -10, currency: .eur),
            bookedAt: date,
            rawMerchantName: "Gemeinsame Suchnadel"
        )
        let wrongSource = Transaction(
            accountID: accountA,
            source: .demo,
            amount: Money(amount: -11, currency: .eur),
            bookedAt: date,
            rawMerchantName: "Gemeinsame Suchnadel"
        )
        let wrongAccount = Transaction(
            accountID: accountB,
            source: .manual,
            amount: Money(amount: -12, currency: .eur),
            bookedAt: date,
            rawMerchantName: "Gemeinsame Suchnadel"
        )
        try await dependencies.transactionRepository.upsert([matching, wrongSource, wrongAccount])

        var query = TransactionQuery(searchText: "gemeinsame suchnadel")
        query.accountIDs = [accountA]
        query.sources = [.manual]
        let page = try await dependencies.transactionRepository.transactionPage(
            matching: query,
            sort: .dateDescending,
            offset: 0,
            limit: 20
        )

        #expect(page.transactions.map(\.id) == [matching.id])
        #expect(!page.hasMore)
    }

    @Test("Konten und Kategorien werden persistiert und gemappt")
    func accountsAndCategoriesRoundtrip() async throws {
        let (_, dependencies) = try makeStore()

        let account = Account(
            name: "Girokonto",
            type: .checking,
            currency: .eur,
            maskedIdentifier: "•••• 4821",
            ibanLast4: "4821",
            source: .demo
        )
        let category = Category.defaultCatalog().first { $0.name == "Lebensmittel" }!

        try await dependencies.accountRepository.upsert([account])
        try await dependencies.categoryRepository.upsert([category])

        let accounts = try await dependencies.accountRepository.accounts()
        let categories = try await dependencies.categoryRepository.categories()

        #expect(accounts.count == 1)
        #expect(accounts.first?.ibanLast4 == "4821")
        #expect(categories.contains(category))
        #expect(categories.first { $0.id == category.id }?.colorToken == .green)
    }

    @Test("Transaction Annotation wird persistiert und gemappt")
    func transactionAnnotationRoundtrip() async throws {
        let (_, dependencies) = try makeStore()
        let transactionID = UUID()
        let tagID = UUID()
        let annotation = TransactionAnnotation(
            transactionID: transactionID,
            note: "Barzahlung prüfen",
            reviewed: true,
            excludedFromAnalytics: true,
            manualKindOverride: .transfer,
            tagIDs: [tagID]
        )

        try await dependencies.transactionAnnotationRepository.upsert([annotation])

        let loaded = try #require(
            try await dependencies.transactionAnnotationRepository.annotation(transactionID: transactionID)
        )
        #expect(loaded.note == "Barzahlung prüfen")
        #expect(loaded.reviewed)
        #expect(loaded.excludedFromAnalytics)
        #expect(loaded.manualKindOverride == .transfer)
        #expect(loaded.tagIDs == [tagID])
    }
}
