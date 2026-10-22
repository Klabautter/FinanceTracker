import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@Suite("Getrennte Konten löschen (Persistenz)")
struct DisconnectedAccountDeletionTests {
    private func transaction(accountID: UUID, amount: Decimal, merchant: String) -> Transaction {
        Transaction(
            accountID: accountID,
            source: .openBanking,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: Date(timeIntervalSince1970: 1_790_000_000),
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
    }

    @Test("Löschen entfernt Konto, Buchungen und Suchindex, andere Konten bleiben unberührt")
    func deletesAccountWithItsTransactionsOnly() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let orphan = Account(name: "Bankkonto", type: .checking, currency: .eur, source: .openBanking, isActive: false)
        let active = Account(name: "Girokonto", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([orphan, active])
        let kept = transaction(accountID: active.id, amount: -5, merchant: "BILLA")
        try await dependencies.transactionRepository.upsert([
            transaction(accountID: orphan.id, amount: -10, merchant: "BILLA"),
            transaction(accountID: orphan.id, amount: -20, merchant: "HOFER"),
            kept
        ])

        try await dependencies.accountRepository.deleteAccountWithTransactions(id: orphan.id)

        let accounts = try await dependencies.accountRepository.accounts()
        #expect(accounts.map(\.id) == [active.id])
        let remaining = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(remaining.map(\.id) == [kept.id])
        let context = ModelContext(store.container)
        let searchRows = try context.fetch(FetchDescriptor<SDTransactionSearchEntity>())
        #expect(searchRows.allSatisfy { $0.transactionID == kept.id })
    }

    @Test("Kontenliste führt getrennte Konten separat und löscht nur diese")
    func modelListsAndDeletesDisconnectedAccounts() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let orphan = Account(name: "Bankkonto", type: .checking, currency: .eur, source: .openBanking, isActive: false)
        let active = Account(name: "Girokonto", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([orphan, active])
        try await dependencies.transactionRepository.upsert([
            transaction(accountID: orphan.id, amount: -10, merchant: "BILLA"),
            transaction(accountID: active.id, amount: -5, merchant: "BILLA")
        ])

        let model = await AccountsModel(dependencies: dependencies)
        await model.load()
        #expect(await model.accounts.map(\.id) == [active.id])
        #expect(await model.disconnectedAccounts.map(\.id) == [orphan.id])
        #expect(await model.disconnectedAccounts.first?.transactionCount == 1)

        // Aktive Konten sind über diesen Weg nicht löschbar.
        await model.deleteDisconnectedAccount(active)
        #expect(await model.accounts.map(\.id) == [active.id])

        await model.deleteDisconnectedAccount(orphan)
        #expect(await model.disconnectedAccounts.isEmpty)
        #expect(try await dependencies.transactionRepository.count() == 1)
    }

    @Test("Belege der gelöschten Buchungen verschwinden als Datei und als Eintrag")
    func deletesAttachmentsOfRemovedTransactions() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let orphan = Account(name: "Bankkonto", type: .checking, currency: .eur, source: .openBanking, isActive: false)
        let active = Account(name: "Girokonto", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([orphan, active])
        let removed = transaction(accountID: orphan.id, amount: -10, merchant: "BILLA")
        let kept = transaction(accountID: active.id, amount: -5, merchant: "BILLA")
        try await dependencies.transactionRepository.upsert([removed, kept])

        try Data("a".utf8).write(to: base.appendingPathComponent("removed.pdf"))
        try Data("b".utf8).write(to: base.appendingPathComponent("kept.pdf"))
        try await dependencies.transactionAttachmentRepository.add(TransactionAttachment(
            transactionID: removed.id, fileName: "removed.pdf", mimeType: "application/pdf", localRelativePath: "removed.pdf"
        ))
        let keptAttachment = TransactionAttachment(
            transactionID: kept.id, fileName: "kept.pdf", mimeType: "application/pdf", localRelativePath: "kept.pdf"
        )
        try await dependencies.transactionAttachmentRepository.add(keptAttachment)

        let model = await AccountsModel(dependencies: dependencies, attachmentsBaseDirectory: base)
        await model.deleteDisconnectedAccount(orphan)

        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("removed.pdf").path))
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("kept.pdf").path))
        #expect(try await dependencies.transactionAttachmentRepository.allAttachments().map(\.id) == [keptAttachment.id])
        #expect(try await dependencies.accountRepository.accounts().map(\.id) == [active.id])
    }

    @Test("Manuelle Konten sind löschbar, Bank-Konten nicht")
    func manualAccountsCanBeDeleted() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let connectionID = UUID()
        let manual = Account(name: "ether.fi Karte", type: .cash, currency: .eur, source: .manual)
        let bank = Account(connectionID: connectionID, name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([manual, bank])
        try await dependencies.transactionRepository.upsert([
            transaction(accountID: manual.id, amount: -10, merchant: "SPAR"),
            transaction(accountID: manual.id, amount: -20, merchant: "BILLA"),
            transaction(accountID: bank.id, amount: -5, merchant: "HOFER")
        ])

        let model = await AccountsModel(dependencies: dependencies)
        await model.load()
        #expect(await model.canDeleteManually(manual))
        #expect(await !model.canDeleteManually(bank))

        await model.deleteManualAccount(bank)
        #expect(try await dependencies.accountRepository.accounts().count == 2)

        await model.deleteManualAccount(manual)
        #expect(try await dependencies.accountRepository.accounts().map(\.id) == [bank.id])
        #expect(try await dependencies.transactionRepository.count() == 1)
        #expect(await model.accounts.map(\.id) == [bank.id])
    }

    private final class BundleMarker {}

    @Test("Mit dem Konto verschwindet auch sein Import aus der Import-Liste, fremde Importe bleiben")
    func deletingAccountRemovesItsEmptiedImportBatch() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let provider = EtherFiCSVProvider(fallbackCurrency: .eur)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur, importProviders: [provider])
        let wrong = Account(name: "Falsches Konto", type: .cash, currency: .eur, source: .manual)
        let other = Account(name: "Anderes Konto", type: .cash, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([wrong, other])

        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "fixture_etherfi_cash", withExtension: "csv"))
        let file = ImportFile(fileName: "fixture_etherfi_cash.csv", data: try Data(contentsOf: url))
        let pipeline = ImportPipeline(
            providers: [provider],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            merchantRepository: dependencies.merchantRepository,
            categoryRepository: dependencies.categoryRepository,
            fallbackCurrency: .eur
        )
        _ = try await pipeline.run(file, into: wrong.id)
        _ = try await pipeline.run(file, into: other.id)
        #expect(try await dependencies.importBatchRepository.batches().count == 2)

        let model = await AccountsModel(dependencies: dependencies)
        await model.deleteManualAccount(wrong)

        let batches = try await dependencies.importBatchRepository.batches()
        #expect(batches.count == 1)
        // Der verbliebene Import gehört zum anderen Konto und ist noch rückholbar.
        let remaining = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(!remaining.isEmpty)
        #expect(remaining.allSatisfy { $0.accountID == other.id })
        #expect(Set(remaining.compactMap(\.importBatchID)) == Set(batches.map(\.id)))
    }
}
