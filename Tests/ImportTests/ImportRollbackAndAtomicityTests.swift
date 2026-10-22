import Foundation
import Testing

@testable import FinanceTracker

@Suite("ImportRollbackAndAtomicity")
struct ImportRollbackAndAtomicityTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func makePipeline(_ dependencies: AppDependencies) -> ImportPipeline {
        ImportPipeline(
            providers: dependencies.importProviders,
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            fallbackCurrency: .eur
        )
    }

    private var pendingThenClearedCSV: String {
        """
        timestamp,type,description,status,amount,currency
        2026-08-23 09:10:38 UTC,card_spend,MCDONALDS 155,%STATUS%,18.3,EUR
        """
    }

    @Test("Rollback stellt aktualisierte Pending-Transaktion wieder her")
    func rollbackRestoresPendingUpdate() async throws {
        let dependencies = try makeDependencies()
        let pipeline = makePipeline(dependencies)
        let accountID = UUID()

        _ = try await pipeline.run(
            ImportFile(fileName: nil, data: Data(pendingThenClearedCSV.replacingOccurrences(of: "%STATUS%", with: "PENDING").utf8)),
            into: accountID
        )

        let before = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(before.count == 1)
        let pendingID = before[0].id
        #expect(before[0].status == .pending)

        _ = try await pipeline.run(
            ImportFile(fileName: nil, data: Data(pendingThenClearedCSV.replacingOccurrences(of: "%STATUS%", with: "CLEARED").utf8)),
            into: accountID
        )

        let afterImport = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(afterImport.count == 1)
        #expect(afterImport[0].status == .booked)

        try await dependencies.importBatchRepository.rollbackImportBatch(id: try #require(await dependencies.importBatchRepository.batches().first?.id))

        let restored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(restored.count == 1)
        #expect(restored[0].id == pendingID)
        #expect(restored[0].status == .pending)
        #expect(restored[0].bookedAt == nil)
        #expect(try await dependencies.importBatchRepository.batches().count == 1)
    }

    @Test("Gemischter Import: Rollback löscht Inserts und stellt Updates her")
    func mixedRollback() async throws {
        let dependencies = try makeDependencies()
        let pipeline = makePipeline(dependencies)
        let accountID = UUID()

        _ = try await pipeline.run(
            ImportFile(fileName: nil, data: Data(pendingThenClearedCSV.replacingOccurrences(of: "%STATUS%", with: "PENDING").utf8)),
            into: accountID
        )

        let mixedCSV = """
        timestamp,type,description,status,amount,currency
        2026-08-24 18:00:00 UTC,card_spend,MCDONALDS 155,CLEARED,18.3,EUR
        2026-08-20 12:00:00 UTC,card_spend,SPAR DANKT,CLEARED,33.08,EUR
        """
        _ = try await pipeline.run(ImportFile(fileName: nil, data: Data(mixedCSV.utf8)), into: accountID)

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.count == 2)

        let lastBatch = try #require(await dependencies.importBatchRepository.batches().first)
        try await dependencies.importBatchRepository.rollbackImportBatch(id: lastBatch.id)

        let restored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(restored.count == 1)
        #expect(restored[0].status == .pending)

        let remainingBatches = try await dependencies.importBatchRepository.batches()
        #expect(remainingBatches.count == 1)
        #expect(remainingBatches.first?.id != lastBatch.id)
    }

    @Test("Fehlgeschlagener Commit hinterlässt keinen Teilzustand")
    func failedCommitIsAtomic() async throws {
        let dependencies = try makeDependencies()
        let pipeline = makePipeline(dependencies)
        let accountID = UUID()

        let file = ImportFile(fileName: nil, data: Data(pendingThenClearedCSV.replacingOccurrences(of: "%STATUS%", with: "PENDING").utf8))
        let prepared = try await pipeline.prepare(file, into: accountID)
        #expect(prepared.transactions.count == 1)

        #if DEBUG
        let batchRepo = dependencies.importBatchRepository as? LocalImportBatchRepository
        try #require(batchRepo != nil)
        struct InjectedError: Error {}
        batchRepo?._testInjectCommitFailure(InjectedError())

        do {
            _ = try await pipeline.commit(prepared)
            Issue.record("Expected injected commit failure")
        } catch is InjectedError {
        }

        #expect(try await dependencies.transactionRepository.count() == 0)
        #expect(try await dependencies.importBatchRepository.batches().isEmpty)
        #else
        _ = prepared
        #endif
    }
}
