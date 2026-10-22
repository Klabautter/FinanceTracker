import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

/// WP17: Analytics und Budgets nutzen die scoped Split-Query
/// allSplitLines bleibt Backup/Migration vorbehalten.
@MainActor
@Suite("SplitQueryScope")
struct SplitQueryScopeTests {

    private func rewire(
        _ dependencies: AppDependencies,
        splitRepository: any TransactionSplitRepository
    ) -> AppDependencies {
        AppDependencies(
            transactionRepository: dependencies.transactionRepository,
            transactionAnnotationRepository: dependencies.transactionAnnotationRepository,
            transactionCollectionRepository: dependencies.transactionCollectionRepository,
            transactionCollectionOverrideRepository: dependencies.transactionCollectionOverrideRepository,
            accountRepository: dependencies.accountRepository,
            categoryRepository: dependencies.categoryRepository,
            merchantRepository: dependencies.merchantRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            connectionRepository: dependencies.connectionRepository,
            budgetRepository: dependencies.budgetRepository,
            tagRepository: dependencies.tagRepository,
            transactionSplitRepository: splitRepository,
            sharedExpenseShareRepository: dependencies.sharedExpenseShareRepository,
            recurringCommitmentRepository: dependencies.recurringCommitmentRepository,
            transactionAttachmentRepository: dependencies.transactionAttachmentRepository,
            bankProviderFactory: dependencies.bankProviderFactory,
            importProviders: dependencies.importProviders,
            changeTracker: dependencies.changeTracker,
            baseCurrency: dependencies.baseCurrency,
            notificationScheduler: dependencies.notificationScheduler
        )
    }

    private func seedStore(_ dependencies: AppDependencies) async throws {
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        var txns: [Transaction] = []
        var lines: [TransactionSplitLine] = []
        for index in 0..<120 {
            let parentID = UUID()
            txns.append(Transaction(
                id: parentID,
                accountID: account.id,
                source: .demo,
                externalID: "split-\(index)",
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -Decimal(index + 1), currency: .eur),
                bookedAt: Date().addingTimeInterval(TimeInterval(-86400 * index)),
                rawDescription: "Händler \(index)",
                rawMerchantName: "Händler \(index)",
                merchantDisplayName: "Händler \(index)"
            ))
            lines.append(TransactionSplitLine(parentTransactionID: parentID, amount: Decimal(index + 1)))
        }
        try await dependencies.transactionRepository.upsert(txns)
        try await dependencies.transactionSplitRepository.upsert(lines)
    }

    @Test("Large set: 120 Parent-Gruppen vollständig per Scoped-Query")
    func largeSetScopedQuery() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        try await seedStore(dependencies)

        let allTxns = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let allLines = try await dependencies.transactionSplitRepository.splitLines(
            parentTransactionIDs: Set(allTxns.map(\.id))
        )
        #expect(allTxns.count == 120)
        #expect(allLines.count == 120)
    }

    @Test("AnalyticsModel ruft allSplitLines nicht mehr auf")
    func analyticsUsesScopedSplits() async throws {
        let store = try SwiftDataStore(inMemory: true)
        var dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        try await seedStore(dependencies)

        let recording = RecordingSplitRepository(base: dependencies.transactionSplitRepository)
        dependencies = rewire(dependencies, splitRepository: recording)

        let model = AnalyticsModel(dependencies: dependencies)
        await model.load()

        #expect(recording.allSplitLinesCallCount == 0)
        #expect(recording.scopedCallCount >= 1)
    }

    @Test("BudgetsModel ruft allSplitLines nicht mehr auf")
    func budgetsUseScopedSplits() async throws {
        let store = try SwiftDataStore(inMemory: true)
        var dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        try await seedStore(dependencies)

        try await dependencies.budgetRepository.upsert([
            Budget(name: "Test", amount: 500, categoryIDs: [])
        ])

        let recording = RecordingSplitRepository(base: dependencies.transactionSplitRepository)
        dependencies = rewire(dependencies, splitRepository: recording)

        let model = BudgetsModel(dependencies: dependencies)
        await model.load()

        #expect(recording.allSplitLinesCallCount == 0)
        #expect(recording.scopedCallCount >= 1)
    }
}
