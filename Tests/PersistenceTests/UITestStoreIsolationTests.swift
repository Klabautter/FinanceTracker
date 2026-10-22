import Foundation
import Testing

@testable import FinanceTracker

/// Normale UI-Prüfungen lesen den Live-Store; nur künstliche Empty-/Error-
/// Zustände sind isoliert. Der lokale Datenreset bleibt separat abgedeckt.
@MainActor
@Suite("UITestStoreIsolation")
struct UITestStoreIsolationTests {

    // MARK: - AppLaunchEnvironment (§9, §11-12)

    private func environment(_ arguments: [String]) -> AppLaunchEnvironment {
        AppLaunchEnvironment(arguments: arguments, configuration: .debug)
    }

    @Test("Privacy-ON-Flag erzwingt true, OFF-Flag erzwingt false")
    func forcedPrivacyFlags() {
        #expect(environment(["-ui-testing-privacy-on"]).forcedPrivacyHidesAmounts == true)
        #expect(environment(["-ui-testing-privacy-off"]).forcedPrivacyHidesAmounts == false)
        #expect(environment([]).forcedPrivacyHidesAmounts == nil)
    }

    @Test("Nur Empty-/Error-Zustände reservieren einen isolierten Store-Pfad")
    func uiTestStoreURLIsolation() {
        #expect(environment([]).uiTestStoreURL == nil)
        #expect(environment(["-ui-testing-privacy-off"]).uiTestStoreURL == nil)
        #expect(environment(["-ui-testing-privacy-on"]).uiTestStoreURL == nil)
        #expect(environment(["-ui-testing-window", "1240x800"]).uiTestStoreURL == nil)

        let url = environment(["-ui-testing-empty"]).uiTestStoreURL
        #expect(url != nil)
        #expect(url?.path.contains("FinanceTrackerUITests") == true)
        #expect(url?.path.contains("FinanceTracker.store") == true)
        // Der Pfad darf niemals dem Production-Store entsprechen (§9).
        #expect(url != SwiftDataStore.liveStoreURL())

        #expect(environment(["-ui-testing-empty"]).uiTestStoreURL != nil)
        #expect(environment(["-ui-testing-error-storage"]).uiTestStoreURL != nil)
    }

    @Test("Isolierter Store an URL-Pfad ist leer und von Production getrennt")
    func isolatedStorePathIsUsable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UITestStoreIsolation-\(UUID().uuidString)")
            .appendingPathComponent("FinanceTracker.store")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = try SwiftDataStore(location: .url(url))
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let count = try await dependencies.transactionRepository.count()
        #expect(count == 0)
    }

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    // MARK: - Vollständiger Reset (WP2, §14/§17)

    @Test("Reset entfernt Budgets, History, Commitments, Occurrences, Tags, Splits, Connections, Batches")
    func resetRemovesAllFinanceData() async throws {
        let dependencies = try makeDependencies()
        let fixture = DemoDataFactory.make()
        try await dependencies.accountRepository.upsert(fixture.accounts)
        try await dependencies.categoryRepository.upsert(fixture.categories)
        try await dependencies.merchantRepository.upsert(fixture.merchants)
        try await dependencies.transactionRepository.upsert(fixture.transactions)
        try await dependencies.budgetRepository.upsert(fixture.budgets)
        try await dependencies.recurringCommitmentRepository.upsert(fixture.commitments)

        // Tag-Join-Row: Join-Rows entstehen via Transaction-Write-through.
        let tag = Tag(name: "Reset-Test-Tag")
        try await dependencies.tagRepository.upsert([tag])
        let accountID = try #require(await dependencies.accountRepository.accounts().first).id
        let txn = Transaction(
            accountID: accountID,
            source: .manual,
            amount: Money(amount: Decimal(string: "-12.34")!, currency: .eur),
            merchantDisplayName: "Reset Test Händler",
            tagIDs: [tag.id]
        )
        try await dependencies.transactionRepository.upsert([txn])
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(transactionID: txn.id, note: "Reset-Test-Notiz")
        ])
        try await dependencies.transactionSplitRepository.upsert([
            TransactionSplitLine(
                parentTransactionID: txn.id,
                amount: Decimal(string: "12.34")!,
                note: "Reset-Test-Split"
            )
        ])
        try await dependencies.connectionRepository.upsert([
            Connection(
                id: UUID(),
                userID: UUID(),
                provider: .gocardless,
                providerConnectionID: "reset-test-connection",
                institutionID: "reset-bank",
                status: .active,
                consentExpiresAt: nil,
                lastSuccessfulSyncAt: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
        ])
        try await dependencies.importBatchRepository.upsert([
            ImportBatch(
                providerIdentifier: "reset-test",
                sourceRaw: "csv",
                fileName: "reset.csv",
                fileHashSHA256: ImportBatch.fileHash(of: Data("reset".utf8)),
                startedAt: Date(),
                completedAt: Date(),
                totalRows: 1,
                importedCount: 1,
                updatedCount: 0,
                duplicateCount: 0,
                failedCount: 0
            )
        ])

        // Akt: Vollständiger Reset (§14).
        try await LocalDataResetService(dependencies: dependencies).wipe()

        #expect(try await dependencies.budgetRepository.budgets().isEmpty)
        #expect(try await dependencies.budgetRepository.amountHistory(budgetID: nil).isEmpty)
        #expect(try await dependencies.recurringCommitmentRepository.commitments().isEmpty)
        #expect(try await dependencies.recurringCommitmentRepository.allOccurrences().isEmpty)
        #expect(try await dependencies.tagRepository.tags().isEmpty)
        #expect(try await dependencies.transactionAnnotationRepository.annotations().isEmpty)
        #expect(try await dependencies.transactionSplitRepository.allSplitLines().isEmpty)
        #expect(try await dependencies.connectionRepository.connections().isEmpty)
        #expect(try await dependencies.importBatchRepository.batches().isEmpty)
        #expect(try await dependencies.transactionRepository.count() == 0)
        #expect(try await dependencies.accountRepository.accounts().isEmpty)
        #expect(try await dependencies.categoryRepository.categories().isEmpty)
        #expect(try await dependencies.merchantRepository.merchants().isEmpty)
        #expect(try await dependencies.ruleRepository.rules().isEmpty)
        #expect(try await dependencies.transactionAttachmentRepository.allAttachments().isEmpty)
        // Suchindex gehört zum Transaction-Scope (§14):
        let searchHits = try await dependencies.transactionRepository.transactions(
            matching: TransactionQuery(searchText: "Reset Test Händler")
        )
        #expect(searchHits.isEmpty)
    }

}
