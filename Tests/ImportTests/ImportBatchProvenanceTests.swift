import Foundation
import Testing

@testable import FinanceTracker

@Suite("ImportBatchProvenance")
struct ImportBatchProvenanceTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private var sampleCSV: Data {
        Data("""
        Date,Memo,Merchant,Amount,Currency
        2026-08-05,Coffee,COFFEE SHOP,-5.40,EUR
        2026-08-06,Groceries,GROCER MART,-62.15,EUR
        """.utf8)
    }

    @Test("Import persistiert Batch, Transaktionen tragen die Batch-ID")
    func batchIsPersistedAndLinked() async throws {
        let dependencies = try makeDependencies()
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            fallbackCurrency: .eur
        )

        let accountID = UUID()
        _ = try await pipeline.run(ImportFile(fileName: "export.csv", data: sampleCSV), into: accountID)

        let batches = try await dependencies.importBatchRepository.batches()
        #expect(batches.count == 1)

        let batch = batches[0]
        #expect(batch.providerIdentifier == "generic_csv")
        #expect(batch.sourceRaw == TransactionSource.genericCSV.rawValue)
        #expect(batch.fileName == "export.csv")
        #expect(batch.fileHashSHA256.count == 64)
        #expect(batch.importedCount == 2)

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.importBatchID == batch.id })
    }

    @Test("Rollback löscht Transaktionen und Batch, fremde Daten bleiben")
    func rollbackRemovesOnlyOwnTransactions() async throws {
        let dependencies = try makeDependencies()
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            fallbackCurrency: .eur
        )

        let accountID = UUID()

        let manualTxn = Transaction(
            accountID: accountID,
            source: .manual,
            amount: Money(amount: -1, currency: .eur),
            bookedAt: Date()
        )
        try await dependencies.transactionRepository.upsert([manualTxn])

        let result = try await pipeline.run(ImportFile(fileName: nil, data: sampleCSV), into: accountID)
        #expect(try await dependencies.transactionRepository.count() == 3)

        let batches = try await dependencies.importBatchRepository.batches()
        let batchID = batches[0].id

        try await dependencies.transactionRepository.deleteTransactions(importBatchID: batchID)
        try await dependencies.importBatchRepository.delete(id: batchID)

        let remaining = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == manualTxn.id)
        #expect(try await dependencies.importBatchRepository.batches().isEmpty)

        _ = result
    }
}
