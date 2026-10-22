import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@Suite("TransactionCollection Persistence")
struct TransactionCollectionPersistenceTests {
    @Test("CRUD und eindeutiger Composite-Key aktualisieren statt zu duplizieren")
    func repositoryCRUD() async throws {
        let (store, dependencies) = try makeDependencies()
        let collection = try makeCollection()
        let secondCollection = try makeCollection()
        let transactionID = UUID()
        try await dependencies.transactionCollectionRepository.upsert([collection, secondCollection])

        let original = TransactionCollectionOverride(
            collectionID: collection.id,
            transactionID: transactionID,
            decision: .include
        )
        var updated = original
        updated.decision = .exclude
        updated.updatedAt = updated.updatedAt.addingTimeInterval(5)
        let secondMembership = TransactionCollectionOverride(
            collectionID: secondCollection.id,
            transactionID: transactionID,
            decision: .include
        )
        try await dependencies.transactionCollectionOverrideRepository.upsert([original, secondMembership])
        try await dependencies.transactionCollectionOverrideRepository.upsert([updated])

        let rows = try ModelContext(store.container).fetch(
            FetchDescriptor<SDTransactionCollectionOverrideEntity>()
        )
        #expect(rows.count == 2)
        #expect(try await dependencies.transactionCollectionOverrideRepository.override(
            collectionID: collection.id,
            transactionID: transactionID
        )?.decision == .exclude)

        try await dependencies.transactionCollectionRepository.delete(id: collection.id)
        #expect(try await dependencies.transactionCollectionRepository.collections().map(\.id) == [secondCollection.id])
        #expect(try await dependencies.transactionCollectionOverrideRepository.allOverrides().map(\.collectionID) == [secondCollection.id])

        try await dependencies.transactionCollectionRepository.deleteAll()
        #expect(try await dependencies.transactionCollectionRepository.collections().isEmpty)
        #expect(try await dependencies.transactionCollectionOverrideRepository.allOverrides().isEmpty)
    }

    @Test("Korrupte Account-JSON und unbekannte Entscheidung werfen")
    func strictDecoding() async throws {
        let (store, dependencies) = try makeDependencies()
        let collection = try makeCollection()
        let override = TransactionCollectionOverride(
            collectionID: collection.id,
            transactionID: UUID(),
            decision: .include
        )
        try await dependencies.transactionCollectionRepository.upsert([collection])
        try await dependencies.transactionCollectionOverrideRepository.upsert([override])

        let context = ModelContext(store.container)
        let collections = try context.fetch(FetchDescriptor<SDTransactionCollectionEntity>())
        collections[0].accountIDsJSON = Data("not-json".utf8)
        let overrides = try context.fetch(FetchDescriptor<SDTransactionCollectionOverrideEntity>())
        overrides[0].decisionRaw = "maybe"
        try context.save()

        await #expect(throws: PersistenceDecodingError.self) {
            _ = try await dependencies.transactionCollectionRepository.collections()
        }
        await #expect(throws: PersistenceDecodingError.self) {
            _ = try await dependencies.transactionCollectionOverrideRepository.allOverrides()
        }
    }

    @Test("Load kombiniert Scope, Overrides, Effective Semantics und Währungssummen")
    func loadUseCase() async throws {
        let (_, dependencies) = try makeDependencies()
        let accountID = UUID()
        let otherAccountID = UUID()
        let start = Date(timeIntervalSince1970: 10_000)
        let end = start.addingTimeInterval(1_000)
        let collection = try TransactionCollection(
            name: "Urlaub",
            systemIconName: "beach.umbrella",
            startDate: start,
            endDateExclusive: end,
            accountIDs: [accountID]
        )
        try await dependencies.transactionCollectionRepository.upsert([collection])

        let included = transaction(accountID: otherAccountID, date: end.addingTimeInterval(10), amount: -30)
        let excluded = transaction(accountID: accountID, date: start.addingTimeInterval(10), amount: -40)
        let effectiveTransfer = transaction(accountID: accountID, date: start.addingTimeInterval(20), amount: -50)
        let usd = transaction(
            accountID: accountID,
            date: start.addingTimeInterval(30),
            amount: -7,
            currency: .usd
        )
        let endBoundary = transaction(accountID: accountID, date: end, amount: -999)
        try await dependencies.transactionRepository.upsert([
            included, excluded, effectiveTransfer, usd, endBoundary
        ])
        try await dependencies.transactionCollectionOverrideRepository.upsert([
            TransactionCollectionOverride(
                collectionID: collection.id,
                transactionID: included.id,
                decision: .include
            ),
            TransactionCollectionOverride(
                collectionID: collection.id,
                transactionID: excluded.id,
                decision: .exclude
            )
        ])
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(
                transactionID: effectiveTransfer.id,
                manualKindOverride: .transfer
            )
        ])

        let snapshot = try await LoadTransactionCollection(
            collectionRepository: dependencies.transactionCollectionRepository,
            overrideRepository: dependencies.transactionCollectionOverrideRepository,
            transactionRepository: dependencies.transactionRepository,
            annotationRepository: dependencies.transactionAnnotationRepository
        )(collectionID: collection.id)

        #expect(Set(snapshot.transactions.map(\.id)) == Set([included.id, effectiveTransfer.id, usd.id]))
        #expect(snapshot.transactions.first { $0.id == effectiveTransfer.id }?.kind == .transfer)
        #expect(snapshot.currencySummaries.first { $0.currency == .eur }?.spending == 30)
        #expect(snapshot.currencySummaries.first { $0.currency == .usd }?.spending == 7)
        #expect(try await dependencies.transactionRepository.transaction(id: effectiveTransfer.id)?.kind == .purchase)
    }

    @Test("Pending-zu-Booked behält ID und damit Collection-Override")
    func pendingBookedStableID() async throws {
        let (_, dependencies) = try makeDependencies()
        let collection = try makeCollection()
        let accountID = try #require(collection.accountIDs.first)
        let transactionID = UUID()
        var pending = transaction(
            id: transactionID,
            accountID: accountID,
            date: collection.startDate.addingTimeInterval(10),
            amount: -12
        )
        pending.status = .pending
        try await dependencies.transactionCollectionRepository.upsert([collection])
        try await dependencies.transactionRepository.upsert([pending])
        try await dependencies.transactionCollectionOverrideRepository.upsert([
            TransactionCollectionOverride(
                collectionID: collection.id,
                transactionID: transactionID,
                decision: .include
            )
        ])

        let pipeline = ImportPipeline(
            providers: [],
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )
        let result = try await pipeline.commitParsedTransactions(
            [ImportedTransaction(
                status: .booked,
                kind: .purchase,
                amount: pending.amount,
                bookedAt: pending.displayDate.addingTimeInterval(60)
            )],
            source: .manual,
            providerIdentifier: "collection-reconciliation-test",
            into: accountID
        )

        #expect(result.updatedCount == 1)
        #expect(try await dependencies.transactionRepository.count() == 1)
        #expect(try await dependencies.transactionRepository.transaction(id: transactionID)?.status == .booked)
        #expect(try await dependencies.transactionCollectionOverrideRepository.override(
            collectionID: collection.id,
            transactionID: transactionID
        ) != nil)
    }

    @Test("V9-Store migriert additiv nach V10")
    func v9Migration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("collection-v9-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store")
        let accountID = UUID()

        do {
            let oldContainer = try ModelContainer(
                for: Schema(versionedSchema: FinanceTrackerSchemaV9.self),
                configurations: [ModelConfiguration(url: url)]
            )
            let context = ModelContext(oldContainer)
            context.insert(SDAccountEntity(
                id: accountID,
                connectionID: nil,
                institutionID: nil,
                name: "Bestand",
                typeRaw: AccountType.checking.rawValue,
                currencyRaw: "EUR",
                maskedIdentifier: nil,
                ibanLast4: nil,
                providerAccountID: nil,
                sourceRaw: AccountSource.manual.rawValue,
                isActive: true
            ))
            try context.save()
        }

        let migrated = try SwiftDataStore(url: url)
        let dependencies = AppDependencies.make(container: migrated.container, baseCurrency: .eur)
        #expect(try await dependencies.accountRepository.account(id: accountID) != nil)
        let collection = try makeCollection(accountIDs: [accountID])
        try await dependencies.transactionCollectionRepository.upsert([collection])
        #expect(try await dependencies.transactionCollectionRepository.collection(id: collection.id) != nil)
    }

    @Test("Reset löscht Overrides und Collections")
    func reset() async throws {
        let (_, dependencies) = try makeDependencies()
        let collection = try makeCollection()
        try await dependencies.transactionCollectionRepository.upsert([collection])
        try await dependencies.transactionCollectionOverrideRepository.upsert([
            TransactionCollectionOverride(
                collectionID: collection.id,
                transactionID: UUID(),
                decision: .include
            )
        ])

        try await LocalDataResetService(dependencies: dependencies).wipe()

        #expect(try await dependencies.transactionCollectionOverrideRepository.allOverrides().isEmpty)
        #expect(try await dependencies.transactionCollectionRepository.collections().isEmpty)
    }

    private func makeDependencies() throws -> (SwiftDataStore, AppDependencies) {
        let store = try SwiftDataStore(inMemory: true)
        return (store, AppDependencies.make(container: store.container, baseCurrency: .eur))
    }

    private func makeCollection(accountIDs: Set<UUID> = [UUID()]) throws -> TransactionCollection {
        try TransactionCollection(
            name: "Pocket",
            systemIconName: "tray.full",
            startDate: Date(timeIntervalSince1970: 1_000),
            endDateExclusive: Date(timeIntervalSince1970: 2_000),
            accountIDs: accountIDs
        )
    }

    private func transaction(
        id: UUID = UUID(),
        accountID: UUID,
        date: Date,
        amount: Decimal,
        currency: CurrencyCode = .eur
    ) -> Transaction {
        Transaction(
            id: id,
            accountID: accountID,
            source: .manual,
            kind: .purchase,
            amount: Money(amount: amount, currency: currency),
            bookedAt: date
        )
    }
}
