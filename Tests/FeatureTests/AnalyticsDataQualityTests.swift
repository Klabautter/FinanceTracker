import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

private enum InjectedRepositoryFailure: Error {
    case read
}

private struct FailingAnnotationRepository: TransactionAnnotationRepository {
    let base: any TransactionAnnotationRepository

    func annotations(transactionIDs: Set<UUID>) async throws -> [TransactionAnnotation] {
        throw InjectedRepositoryFailure.read
    }

    func annotation(transactionID: UUID) async throws -> TransactionAnnotation? {
        try await base.annotation(transactionID: transactionID)
    }

    func upsert(_ annotations: [TransactionAnnotation]) async throws {
        try await base.upsert(annotations)
    }

    func delete(transactionID: UUID) async throws {
        try await base.delete(transactionID: transactionID)
    }

    func deleteAll() async throws {
        try await base.deleteAll()
    }
}

private struct FailingSplitRepository: TransactionSplitRepository {
    let base: any TransactionSplitRepository

    func allSplitLines() async throws -> [TransactionSplitLine] {
        try await base.allSplitLines()
    }

    func deleteAll() async throws {
        try await base.deleteAll()
    }

    func splitLines(parentTransactionID: UUID) async throws -> [TransactionSplitLine] {
        try await base.splitLines(parentTransactionID: parentTransactionID)
    }

    func splitLines(parentTransactionIDs: Set<UUID>) async throws -> [TransactionSplitLine] {
        throw InjectedRepositoryFailure.read
    }

    func upsert(_ lines: [TransactionSplitLine]) async throws {
        try await base.upsert(lines)
    }

    func deleteAll(parentTransactionID: UUID) async throws {
        try await base.deleteAll(parentTransactionID: parentTransactionID)
    }
}

@MainActor
@Suite("AnalyticsDataQuality")
struct AnalyticsDataQualityTests {
    @Test("Analytics meldet Split-Read-Fehler statt einer unvollständigen Summe")
    func analyticsSplitReadFailureDoesNotProduceSnapshot() async throws {
        let (store, baseDependencies) = try await populatedDependencies()
        _ = store
        let dependencies = replacing(
            baseDependencies,
            splitRepository: FailingSplitRepository(base: baseDependencies.transactionSplitRepository)
        )
        let model = AnalyticsModel(dependencies: dependencies)

        await model.load()

        #expect(model.errorMessage != nil)
        #expect(model.snapshot == nil)
        #expect(model.previousSnapshot == nil)
        #expect(model.isLoading == false)
    }

    @Test("Analytics meldet Annotation-Read-Fehler statt Rohdaten als gültig auszugeben")
    func analyticsAnnotationReadFailureDoesNotProduceSnapshot() async throws {
        let (store, baseDependencies) = try await populatedDependencies()
        _ = store
        let dependencies = replacing(
            baseDependencies,
            annotationRepository: FailingAnnotationRepository(base: baseDependencies.transactionAnnotationRepository)
        )
        let model = AnalyticsModel(dependencies: dependencies)

        await model.load()

        #expect(model.errorMessage != nil)
        #expect(model.snapshot == nil)
        #expect(model.isLoading == false)
    }

    @Test("Dashboard meldet Split-Read-Fehler statt einer falschen Nullsumme")
    func dashboardSplitReadFailureDoesNotProduceSnapshot() async throws {
        let (store, baseDependencies) = try await populatedDependencies()
        _ = store
        let dependencies = replacing(
            baseDependencies,
            splitRepository: FailingSplitRepository(base: baseDependencies.transactionSplitRepository)
        )
        let model = DashboardModel(dependencies: dependencies)

        await model.load()

        #expect(model.errorMessage != nil)
        #expect(model.snapshot == nil)
        #expect(model.isLoading == false)
    }

    private func populatedDependencies() async throws -> (SwiftDataStore, AppDependencies) {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let transaction = Transaction(
            accountID: account.id,
            source: .manual,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -25, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Fehlertest"
        )
        try await dependencies.transactionRepository.upsert([transaction])
        return (store, dependencies)
    }

    private func replacing(
        _ dependencies: AppDependencies,
        annotationRepository: (any TransactionAnnotationRepository)? = nil,
        splitRepository: (any TransactionSplitRepository)? = nil
    ) -> AppDependencies {
        AppDependencies(
            transactionRepository: dependencies.transactionRepository,
            transactionAnnotationRepository: annotationRepository ?? dependencies.transactionAnnotationRepository,
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
            transactionSplitRepository: splitRepository ?? dependencies.transactionSplitRepository,
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
}
