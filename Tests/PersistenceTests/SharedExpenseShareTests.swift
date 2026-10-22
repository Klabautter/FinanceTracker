import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@MainActor
@Suite("SharedExpenseSharePersistence")
struct SharedExpenseSharePersistenceTests {
    private func makeDependencies() throws -> (AppDependencies, SwiftDataStore) {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        return (dependencies, store)
    }

    private func sampleTransaction(id: UUID = UUID()) -> Transaction {
        Transaction(
            id: id,
            accountID: UUID(),
            source: .manual,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -90, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Abendessen",
            rawMerchantName: "Ristorante",
            merchantDisplayName: "Ristorante"
        )
    }

    private func sampleShare(
        transactionID: UUID,
        paidBy: String = "Alex",
        owedBy: String = "Mara",
        amount: Decimal = 30,
        currency: CurrencyCode = .eur,
        settled: Bool = false
    ) throws -> SharedExpenseShare {
        try SharedExpenseShare(
            transactionID: transactionID,
            paidBy: paidBy,
            owedBy: owedBy,
            shareAmount: amount,
            shareCurrency: currency,
            settled: settled
        )
    }

    @Test("Roundtrip: speichern, laden, settled umschalten, löschen")
    func roundtrip() async throws {
        let (dependencies, _) = try makeDependencies()
        let txn = sampleTransaction()
        try await dependencies.transactionRepository.upsert([txn])

        let share = try sampleShare(transactionID: txn.id)
        try await dependencies.sharedExpenseShareRepository.upsert([share])

        var loaded = try await dependencies.sharedExpenseShareRepository.shares(transactionID: txn.id)
        #expect(loaded.count == 1)
        #expect(loaded.first?.paidBy == "Alex")
        #expect(loaded.first?.owedBy == "Mara")
        #expect(loaded.first?.shareAmount == 30)
        #expect(loaded.first?.shareCurrency == .eur)
        #expect(loaded.first?.settled == false)

        // Settled-Update via Upsert.
        var settled = try #require(loaded.first)
        settled.settled = true
        settled.updatedAt = Date()
        try await dependencies.sharedExpenseShareRepository.upsert([settled])

        loaded = try await dependencies.sharedExpenseShareRepository.shares(transactionID: txn.id)
        #expect(loaded.first?.settled == true)

        // Scoped Query über mehrere IDs.
        let otherTxnID = UUID()
        let otherShare = try sampleShare(transactionID: otherTxnID, paidBy: "Alex", owedBy: "Jon", amount: 10)
        try await dependencies.sharedExpenseShareRepository.upsert([otherShare])
        let scoped = try await dependencies.sharedExpenseShareRepository.shares(
            transactionIDs: [txn.id]
        )
        #expect(scoped.count == 1)
        #expect(scoped.first?.transactionID == txn.id)

        let all = try await dependencies.sharedExpenseShareRepository.allShares()
        #expect(all.count == 2)

        // Einzel-Löschung.
        try await dependencies.sharedExpenseShareRepository.delete(id: share.id)
        loaded = try await dependencies.sharedExpenseShareRepository.shares(transactionID: txn.id)
        #expect(loaded.isEmpty)

        // Scope-Löschung.
        try await dependencies.sharedExpenseShareRepository.deleteAll(transactionID: otherTxnID)
        #expect(try await dependencies.sharedExpenseShareRepository.allShares().isEmpty)
    }

    @Test("Korrupter Betrag wirft statt 0 zu maskieren (#23)")
    func corruptAmountThrows() async throws {
        let (dependencies, store) = try makeDependencies()
        let txn = sampleTransaction()
        try await dependencies.transactionRepository.upsert([txn])
        let initialShare = try sampleShare(transactionID: txn.id)
        try await dependencies.sharedExpenseShareRepository.upsert([initialShare])

        let context = ModelContext(store.container)
        let rows = try context.fetch(FetchDescriptor<SDSharedExpenseShareEntity>())
        #expect(rows.count == 1)
        rows[0].shareAmountValue = "not-a-number"
        try context.save()

        await #expect(throws: PersistenceDecodingError.self) {
            _ = try await dependencies.sharedExpenseShareRepository.shares(transactionID: txn.id)
        }
    }

    @Test("Null-/Negativ-Betrag in der DB wirft (#23)")
    func nonPositiveAmountThrows() async throws {
        let (dependencies, store) = try makeDependencies()
        let txn = sampleTransaction()
        try await dependencies.transactionRepository.upsert([txn])
        let zeroProbe = try sampleShare(transactionID: txn.id)
        try await dependencies.sharedExpenseShareRepository.upsert([zeroProbe])

        let context = ModelContext(store.container)
        let rows = try context.fetch(FetchDescriptor<SDSharedExpenseShareEntity>())
        rows[0].shareAmountValue = "0"
        try context.save()

        await #expect(throws: PersistenceDecodingError.self) {
            _ = try await dependencies.sharedExpenseShareRepository.shares(transactionID: txn.id)
        }
    }

    @Test("Korrupte Teilnehmer werfen statt zu maskieren (#23)")
    func corruptParticipantsThrow() async throws {
        let (dependencies, store) = try makeDependencies()
        let txn = sampleTransaction()
        try await dependencies.transactionRepository.upsert([txn])
        let participantProbe = try sampleShare(transactionID: txn.id)
        try await dependencies.sharedExpenseShareRepository.upsert([participantProbe])

        let context = ModelContext(store.container)
        let rows = try context.fetch(FetchDescriptor<SDSharedExpenseShareEntity>())
        rows[0].paidBy = "Alex"
        rows[0].owedBy = "Alex"
        try context.save()

        await #expect(throws: PersistenceDecodingError.self) {
            _ = try await dependencies.sharedExpenseShareRepository.shares(transactionID: txn.id)
        }
    }

    @Test("Cascade: Transaktions-Löschung entfernt Anteile")
    func cascadeOnTransactionDelete() async throws {
        let (dependencies, _) = try makeDependencies()
        let txn = sampleTransaction()
        try await dependencies.transactionRepository.upsert([txn])
        let firstShare = try sampleShare(transactionID: txn.id, owedBy: "Mara")
        let secondShare = try sampleShare(transactionID: txn.id, owedBy: "Jon", amount: 20)
        try await dependencies.sharedExpenseShareRepository.upsert([firstShare, secondShare])
        #expect(try await dependencies.sharedExpenseShareRepository.shares(transactionID: txn.id).count == 2)

        try await dependencies.transactionRepository.deleteAll()
        #expect(try await dependencies.sharedExpenseShareRepository.allShares().isEmpty)
    }

    @Test("V11-Store wird zu V12 migriert, Daten bleiben, Shares nutzbar")
    func migrationV11ToV12PreservesData() async throws {
        let txnID = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("groupexpense-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("migration.store")
        defer { try? FileManager.default.removeItem(at: directory) }

        // 1) V11-Store mit Transaktion schreiben.
        do {
            let configuration = ModelConfiguration(url: storeURL)
            let oldContainer = try ModelContainer(
                for: Schema(FinanceTrackerSchemaV11.models),
                configurations: [configuration]
            )
            let context = ModelContext(oldContainer)
            context.insert(SDTransactionEntity(
                id: txnID,
                accountID: UUID(),
                sourceRaw: "manual",
                externalID: "mig-group-1",
                sourceFingerprint: nil,
                statusRaw: "booked",
                kindRaw: "purchase",
                amountValue: "-90.00",
                amountCurrencyRaw: "EUR",
                bookedAt: Date(),
                authorizedAt: nil,
                valueDate: nil,
                effectiveDateValue: Date(),
                rawDescription: "Abendessen",
                rawMerchantName: "Ristorante",
                merchantID: nil,
                merchantDisplayName: "Ristorante",
                categoryID: nil,
                paymentMethodRaw: nil,
                originalCurrencyRaw: nil,
                originalAmountValue: nil,
                cryptoAsset: nil,
                cryptoAmountValue: nil,
                cashbackAmountValue: nil,
                cashbackCurrencyRaw: nil,
                importBatchID: nil,
                searchableText: "ristorante",
                note: nil,
                reviewed: false,
                excludedFromAnalytics: false,
                tagIDsJSON: nil,
                createdAt: Date(),
                updatedAt: Date()
            ))
            try context.save()
        }

        // 2) Mit V12-Plan öffnen (V11 → V12 lightweight).
        let migrated = try SwiftDataStore(url: storeURL)
        let dependencies = AppDependencies.make(container: migrated.container, baseCurrency: .eur)
        let context = ModelContext(migrated.container)

        let txnRows = try context.fetch(FetchDescriptor<SDTransactionEntity>())
        #expect(txnRows.count == 1)
        #expect(txnRows.first?.id == txnID)

        // 3) Neue V12-Funktion: Share schreiben und lesen.
        let migratedShare = try sampleShare(transactionID: txnID)
        try await dependencies.sharedExpenseShareRepository.upsert([migratedShare])
        let shares = try await dependencies.sharedExpenseShareRepository.shares(transactionID: txnID)
        #expect(shares.count == 1)
        #expect(shares.first?.owedBy == "Mara")
    }
}
