import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("ImportModel")
struct ImportModelTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func makeModelWithAccount() async throws -> (AppDependencies, ImportModel) {
        let dependencies = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "ether.fi Cash", type: .cryptoCard, currency: .eur, source: .csvImport)
        ])
        let model = ImportModel(dependencies: dependencies)
        await model.loadAccounts()
        try #require(model.selectedAccountID != nil)
        return (dependencies, model)
    }

    private func writeTempCSV(_ name: String, _ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).csv")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var initialCSV: String {
        """
        timestamp,type,description,status,amount,currency,card,card holder name,original amount,original currency,cashback earned,cashback currency,category,spending mode
        2026-08-23 09:10:38 UTC,card_spend,MCDONALDS 155,PENDING,18.3,EUR,0000,TEST USER,18.3,EUR,0.55,EUR,Food,Direct Pay
        2026-07-31 06:46:57 UTC,card_spend,SP OPTIMIZE.BIKE,CLEARED,16.49,EUR,0000,TEST USER,16.49,EUR,0.49,EUR,Transport,Direct Pay
        """
    }

    private var updateOnlyCSV: String {
        """
        timestamp,type,description,status,amount,currency,card,card holder name,original amount,original currency,cashback earned,cashback currency,category,spending mode
        2026-08-24 18:00:00 UTC,card_spend,MCDONALDS 155,CLEARED,18.3,EUR,0000,TEST USER,18.3,EUR,0.55,EUR,Food,Direct Pay
        2026-07-31 06:46:57 UTC,card_spend,SP OPTIMIZE.BIKE,CLEARED,16.49,EUR,0000,TEST USER,16.49,EUR,0.49,EUR,Transport,Direct Pay
        """
    }

    @Test("Ohne Konto wird Konto-Erstellung angeboten und fortgesetzt")
    func needsAccountFlow() async throws {
        let dependencies = try makeDependencies()
        let model = ImportModel(dependencies: dependencies)
        await model.loadAccounts()
        #expect(model.accounts.isEmpty)

        let url = try writeTempCSV("fresh", initialCSV)
        await model.prepareFile(at: url)

        guard case .needsAccount(let suggested) = model.phase else {
            Issue.record("Expected needsAccount, got \(model.phase)")
            return
        }
        // Das Konto benennt der Nutzer, aus dem Dateiformat wird kein Name abgeleitet.
        #expect(suggested.isEmpty)

        await model.createAccountAndContinue(named: "Meine Karte")

        guard case .reviewing = model.phase else {
            Issue.record("Expected reviewing after account creation, got \(model.phase)")
            return
        }
        #expect(try await dependencies.accountRepository.accounts().count == 1)

        await model.confirmImport()

        #expect(try await dependencies.transactionRepository.count() == 2)
        let batches = try await dependencies.importBatchRepository.batches()
        #expect(batches.count == 1)
    }

    @Test("Rollback über History entfernt Batch und Transaktionen")
    func historyRollbackRemovesEverything() async throws {
        let (dependencies, model) = try await makeModelWithAccount()

        let url = try writeTempCSV("hist", initialCSV)
        await model.prepareFile(at: url)
        await model.confirmImport()
        await model.loadHistory()

        #expect(try await dependencies.transactionRepository.count() == 2)
        let batchID = try #require(await dependencies.importBatchRepository.batches().first?.id)

        await model.rollback(batchID: batchID)

        #expect(try await dependencies.transactionRepository.count() == 0)
        #expect(try await dependencies.importBatchRepository.batches().isEmpty)
        _ = dependencies
    }

    @Test("Update-only-Vorschau wird nicht als abgeschlossen übersprungen")
    func updateOnlyImportGoesToReview() async throws {
        let (dependencies, model) = try await makeModelWithAccount()

        let firstURL = try writeTempCSV("initial", initialCSV)
        await model.prepareFile(at: firstURL)

        guard case .reviewing = model.phase else {
            Issue.record("Expected reviewing after first import, got \(model.phase)")
            return
        }
        await model.confirmImport()

        #expect(try await dependencies.transactionRepository.count() == 2)
        let storedBefore = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(storedBefore.filter { $0.status == .pending }.count == 1)

        let secondURL = try writeTempCSV("update", updateOnlyCSV)
        await model.prepareFile(at: secondURL)

        guard case .reviewing = model.phase else {
            Issue.record("Update-only import must go to review, got \(model.phase)")
            return
        }
        let prepared = model.preparedImport
        #expect(prepared?.transactions.isEmpty == true)
        #expect(prepared?.updates.count == 1)
        #expect(prepared?.duplicateCount == 1)

        await model.confirmImport()

        let storedAfter = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(storedAfter.count == 2)
        let mcdonalds = try #require(storedAfter.first { $0.effectiveMerchantName.contains("McDonald") })
        #expect(mcdonalds.status == .booked)
        #expect(mcdonalds.bookedAt != nil)
    }

    @Test("Alles-Duplikate landen weiterhin direkt im Ergebnis ohne Commit-Schaden")
    func allDuplicatesShortCircuit() async throws {
        let (dependencies, model) = try await makeModelWithAccount()

        let url = try writeTempCSV("dup", initialCSV)
        await model.prepareFile(at: url)
        await model.confirmImport()
        #expect(try await dependencies.transactionRepository.count() == 2)

        let sameAgain = try writeTempCSV("dup2", initialCSV)
        await model.prepareFile(at: sameAgain)

        guard case .completed(let result) = model.phase else {
            Issue.record("Expected completed for all-duplicates, got \(model.phase)")
            return
        }
        #expect(result.importedCount == 0)
        #expect(result.duplicateCount == 2)
        #expect(!model.canRollbackLastImport, "Ein Ergebnis ohne Batch darf keinen Rollback für einen älteren Import anbieten")
        #expect(try await dependencies.transactionRepository.count() == 2)
    }

    @Test("Review zeigt das vorbereitete Importziel und fixiert die Auswahl")
    func preparedTargetAccountIsBoundToPreview() async throws {
        let (dependencies, model) = try await makeModelWithAccount()
        let preparedAccountID = try #require(model.selectedAccountID)
        let otherAccount = Account(name: "Privatkonto", type: .checking, currency: .eur, source: .csvImport)
        try await dependencies.accountRepository.upsert([otherAccount])
        await model.loadAccounts()

        let url = try writeTempCSV("target-preview", initialCSV)
        await model.prepareFile(at: url)

        guard case .reviewing = model.phase else {
            Issue.record("Expected reviewing, got \(model.phase)")
            return
        }
        #expect(model.preparedImport?.targetAccountID == preparedAccountID)
        #expect(model.preparedTargetAccountName == "ether.fi Cash")
        #expect(!model.canChangeTargetAccount)

        model.selectedAccountID = otherAccount.id
        #expect(model.preparedImport?.targetAccountID == preparedAccountID)
        #expect(model.preparedTargetAccountName == "ether.fi Cash")

        await model.confirmImport()

        let importedTransactions = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(importedTransactions.count == 2)
        #expect(importedTransactions.allSatisfy { $0.accountID == preparedAccountID })
    }

    @Test("Fehler des Datei-Pickers wird als sichtbarer Fehlerzustand übernommen")
    func filePickerFailureIsVisible() throws {
        let model = ImportModel(dependencies: try makeDependencies())

        model.fileSelectionFailed()

        guard case .failed(let message) = model.phase else {
            Issue.record("Expected failed, got \(model.phase)")
            return
        }
        #expect(message.contains("Dateiauswahl"))
        #expect(!model.canRollbackLastImport)
    }
}
