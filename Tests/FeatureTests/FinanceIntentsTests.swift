#if DEBUG
import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("FinanceIntents")
struct FinanceIntentsTests {
    @Test("Kurzbefehl nutzt dieselben Monatszahlen wie die Übersicht")
    func summaryMatchesDashboard() async throws {
        let store = try SwiftDataStore(inMemory: true)
        PreviewDependencies.seedDemoData(into: store.container)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let summary = try await MonthSummary.current(dependencies: dependencies)
        let model = DashboardModel(dependencies: dependencies)
        await model.load()
        #expect(summary.spending == model.snapshot?.totalSpending)
        #expect(summary.available == model.forecast?.availableAmount)
        #expect(summary.spending > 0)
    }

    @Test("Ohne Buchungen meldet der Kurzbefehl das statt 0 €")
    func emptyStoreSaysSo() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let summary = try? await MonthSummary.current(dependencies: dependencies)
        #expect(summary == nil || summary?.spending == 0)
    }
}
#endif
