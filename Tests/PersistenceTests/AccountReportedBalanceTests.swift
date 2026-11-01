import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@Suite("Gemeldeter Kontostand (Persistenz)")
struct AccountReportedBalanceTests {
    private func balance(_ amount: Decimal, at seconds: TimeInterval, source: ReportedBalance.Source = .bank) -> ReportedBalance {
        ReportedBalance(amount: Money(amount: amount, currency: .eur), asOf: Date(timeIntervalSince1970: seconds), source: source)
    }

    @Test("Stand überlebt den Roundtrip, ein älterer ersetzt keinen neueren")
    func roundTripAndOrdering() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([account])

        try await dependencies.accountRepository.saveReportedBalance(balance(1000, at: 2_000), accountID: account.id)
        try await dependencies.accountRepository.saveReportedBalance(balance(800, at: 1_000, source: .file), accountID: account.id)
        var loaded = try #require(try await dependencies.accountRepository.account(id: account.id))
        #expect(loaded.reportedBalance == balance(1000, at: 2_000))

        try await dependencies.accountRepository.saveReportedBalance(balance(1200, at: 3_000), accountID: account.id)
        loaded = try #require(try await dependencies.accountRepository.account(id: account.id))
        #expect(loaded.reportedBalance == balance(1200, at: 3_000))

        // Ein normales Konto-Update (z. B. Umbenennen) lässt den Stand stehen.
        var renamed = loaded
        renamed.name = "Hauptkonto"
        renamed.reportedBalance = nil
        try await dependencies.accountRepository.upsert([renamed])
        loaded = try #require(try await dependencies.accountRepository.account(id: account.id))
        #expect(loaded.reportedBalance == balance(1200, at: 3_000))
    }

    @Test("Korrupter Stand wirft statt 0")
    func corruptThrows() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.accountRepository.saveReportedBalance(balance(1, at: 1), accountID: account.id)

        let context = ModelContext(store.container)
        let rows = try context.fetch(FetchDescriptor<SDAccountReportedBalanceEntity>())
        rows[0].amountValue = "viel"
        try context.save()
        await #expect(throws: PersistenceDecodingError.self) {
            _ = try await dependencies.accountRepository.accounts()
        }
    }

    @Test("Konto löschen entfernt auch den Stand")
    func deletionRemovesSidecar() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.accountRepository.saveReportedBalance(balance(1, at: 1), accountID: account.id)

        try await dependencies.accountRepository.deleteAccountWithTransactions(id: account.id)
        let context = ModelContext(store.container)
        #expect(try context.fetch(FetchDescriptor<SDAccountReportedBalanceEntity>()).isEmpty)
    }

    @Test("Datei-Import mit Saldo-Spalte speichert den Stand; Kontenliste rechnet spätere Buchungen dazu")
    @MainActor
    func importStoresBalance() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .csvImport)
        try await dependencies.accountRepository.upsert([account])
        let csv = """
        Datum;Beschreibung;Betrag;Saldo
        01.10.2026;REWE;-20,00;980,00
        02.10.2026;Miete;-500,00;480,00
        """
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            accountRepository: dependencies.accountRepository,
            fallbackCurrency: .eur
        )
        _ = try await pipeline.run(ImportFile(fileName: "giro.csv", data: Data(csv.utf8)), into: account.id)

        let loaded = try #require(try await dependencies.accountRepository.account(id: account.id))
        #expect(loaded.reportedBalance?.amount == Money(amount: 480, currency: .eur))
        #expect(loaded.reportedBalance?.source == .file)

        try await dependencies.transactionRepository.upsert([
            Transaction(accountID: account.id, source: .manual, amount: Money(amount: -30, currency: .eur), bookedAt: Date())
        ])
        let model = AccountsModel(dependencies: dependencies)
        await model.load()
        let summary = try #require(model.accounts.first)
        #expect(summary.balance == Money(amount: 450, currency: .eur))
        #expect(model.liquidity?.total == Money(amount: 450, currency: .eur))
    }

    @Test("Erneuter Import einer schon importierten Datei holt den Stand nach, ohne leeren Verlaufseintrag")
    @MainActor
    func reimportBackfillsBalance() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .csvImport)
        try await dependencies.accountRepository.upsert([account])
        let file = ImportFile(fileName: "giro.csv", data: Data("""
        Datum;Beschreibung;Betrag;Saldo
        01.10.2026;REWE;-20,00;980,00
        02.10.2026;Miete;-500,00;480,00
        """.utf8))
        let provider = GenericCSVProvider(fallbackCurrency: .eur)

        // Import wie vor 0.4.0: ohne Konten-Repository, also ohne Stand.
        let oldPipeline = ImportPipeline(
            providers: [provider],
            transactionRepository: dependencies.transactionRepository,
            importBatchRepository: dependencies.importBatchRepository,
            fallbackCurrency: .eur
        )
        _ = try await oldPipeline.run(file, into: account.id)
        #expect(try await dependencies.accountRepository.account(id: account.id)?.reportedBalance == nil)
        let batchesBefore = try await dependencies.importBatchRepository.batches().count

        let pipeline = ImportPipeline(
            providers: [provider],
            transactionRepository: dependencies.transactionRepository,
            importBatchRepository: dependencies.importBatchRepository,
            accountRepository: dependencies.accountRepository,
            fallbackCurrency: .eur
        )
        let prepared = try await pipeline.prepare(file, into: account.id)
        #expect(prepared.transactions.isEmpty)
        #expect(prepared.reportedBalanceIsNew)
        #expect(prepared.hasChanges)
        _ = try await pipeline.commit(prepared)

        let stored = try await dependencies.accountRepository.account(id: account.id)
        #expect(stored?.reportedBalance?.amount == Money(amount: 480, currency: .eur))
        #expect(try await dependencies.importBatchRepository.batches().count == batchesBefore)

        // Ein weiteres Mal: nichts Neues mehr, auch kein neuer Stand.
        let again = try await pipeline.prepare(file, into: account.id)
        #expect(!again.reportedBalanceIsNew)
        #expect(!again.hasChanges)
    }
}
