import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("FixkostenCreateModel")
struct FixkostenCreateModelTests {
    @Test("Speichert den Plan mit gewähltem Händler; ohne Betrag nicht")
    func savesWithMerchant() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let model = FixkostenCreateModel(dependencies: dependencies)
        model.name = "Miete"
        #expect(!model.canSave)
        #expect(await model.save() == false)
        #expect(model.actionError != nil)

        model.amount = 985
        model.merchantKey = "account:v1:\(UUID().uuidString)|vermieter"
        #expect(model.canSave)
        #expect(await model.save())
        #expect(model.actionError == nil)
        let stored = try await dependencies.recurringCommitmentRepository.commitments()
        #expect(stored.count == 1)
        #expect(stored.first?.merchantKey == model.merchantKey)
        #expect(stored.first?.expectedAmount == 985)
    }
}
