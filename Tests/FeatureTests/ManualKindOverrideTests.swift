import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("ManualKindOverride")
struct ManualKindOverrideTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    @Test("setManualKind persistiert Override, Resolver übernimmt ihn, Reset entfernt ihn")
    func overrideLifecycle() async throws {
        let dependencies = try makeDependencies()
        let model = TransactionsModel(dependencies: dependencies)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let txn = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .demo,
            externalID: "override-1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(string: "300.00")!, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Überweisung",
            rawMerchantName: "Bank",
            merchantDisplayName: "Bank"
        )
        try await dependencies.transactionRepository.upsert([txn])
        await model.refresh()

        // Override: Transfer (User gewinnt über Detector: Roadmap #64)
        await model.setManualKind(.transfer, on: model.transactions[0])
        #expect(model.transactions[0].kind == .transfer)
        #expect(model.manualKindOverrides[txn.id] == .transfer)

        // Persistiert in der Annotation
        let annotation = try #require(
            await dependencies.transactionAnnotationRepository.annotation(transactionID: txn.id)
        )
        #expect(annotation.manualKindOverride == .transfer)

        // Reset: Override entfernen
        await model.setManualKind(nil, on: model.transactions[0])
        #expect(model.transactions[0].kind == .purchase)
        #expect(model.manualKindOverrides[txn.id] == nil)

        let annotationAfterReset = try #require(
            await dependencies.transactionAnnotationRepository.annotation(transactionID: txn.id)
        )
        #expect(annotationAfterReset.manualKindOverride == nil)
    }
}
