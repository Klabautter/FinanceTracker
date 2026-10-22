import Testing

@testable import FinanceTracker

/// Leerer Store: Das Transaktionsmodell muss nach dem ersten Laden in einen
/// eindeutigen Leerzustand kommen (kein Laden mehr, kein Fehler), damit die
/// View den Empty-State mit Einstiegsaktionen zeigen kann.
@Suite("Transaktionen: Leerzustand")
struct TransactionsEmptyStateTests {
    @Test("Leerer Store → geladen, leer, ohne Fehler")
    @MainActor
    func emptyStoreReachesEmptyState() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        await SystemCatalogSeeder(dependencies: dependencies).seedIfNeeded()
        let model = TransactionsModel(dependencies: dependencies)

        await model.refresh()

        #expect(model.hasLoadedData, "hasLoadedData")
        #expect(!model.isLoading, "isLoading=\(model.isLoading)")
        #expect(model.transactions.isEmpty, "transactions=\(model.transactions.count)")
        #expect(model.errorMessage == nil, "error=\(model.errorMessage ?? "nil")")
    }
}
