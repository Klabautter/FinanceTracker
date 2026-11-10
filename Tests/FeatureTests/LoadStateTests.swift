import Foundation
import Testing

@testable import FinanceTracker

/// AGENTS #37: Ladezustand als ein Wert, Aktionsfehler getrennt davon.
@MainActor
@Suite("LoadState")
struct LoadStateTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    @Test("ScreenState: Inhalt gewinnt immer, sonst Fehler vor Laden vor leer")
    func screenStateResolution() {
        #expect(ScreenState(load: .idle, hasContent: false) == .loading)
        #expect(ScreenState(load: .loading, hasContent: false) == .loading)
        #expect(ScreenState(load: .failed("x"), hasContent: false) == .failed("x"))
        #expect(ScreenState(load: .loaded, hasContent: false) == .empty)
        // Daten werden nie von Spinner oder Fehlerseite verdeckt.
        #expect(ScreenState(load: .loading, hasContent: true) == .content)
        #expect(ScreenState(load: .failed("x"), hasContent: true) == .content)
        #expect(LoadState.failed("x").failureMessage == "x")
        #expect(LoadState.loaded.failureMessage == nil)
        #expect(LoadState.loading.isLoading)
    }

    @Test("Kategorien: ein Eingabefehler ist kein Ladefehler und verdeckt den Leerzustand nicht")
    func categoriesValidationErrorIsAnActionError() async throws {
        let dependencies = try makeDependencies()
        let model = CategoriesModel(dependencies: dependencies)
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(ScreenState(load: model.loadState, hasContent: !model.groups.isEmpty) == .empty)

        await model.createCategory(name: "   ", icon: "tag", color: .blue, parentID: nil)

        #expect(model.actionError == "Bitte einen Namen eingeben.")
        #expect(model.loadState == .loaded)
        #expect(ScreenState(load: model.loadState, hasContent: !model.groups.isEmpty) == .empty)
        model.dismissActionError()
        #expect(model.actionError == nil)
    }

    @Test("Gruppenausgaben: Eingabefehler bleibt Eingabefehler, Laden bleibt geladen")
    func groupExpenseValidationKeepsLoadState() async throws {
        let dependencies = try makeDependencies()
        let transaction = Transaction(
            accountID: UUID(), source: .manual, status: .booked, kind: .purchase,
            amount: Money(amount: -90, currency: .eur), bookedAt: Date(), rawDescription: "Abendessen"
        )
        try await dependencies.transactionRepository.upsert([transaction])
        let model = GroupExpenseSectionModel(transaction: transaction, dependencies: dependencies)
        await model.load()

        let ok = await model.addShare(paidBy: "Alex", owedBy: "Alex", amountText: "10", currency: .eur)

        #expect(!ok)
        #expect(model.actionError != nil)
        #expect(model.loadState == .loaded)
        #expect(ScreenState(load: model.loadState, hasContent: !model.shares.isEmpty) == .empty)
    }

    @Test("Sammlungen: ein abgebrochenes Laden der Kandidaten lässt keinen Spinner stehen")
    func cancelledCandidateLoadResetsFlag() async throws {
        let dependencies = try makeDependencies()
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let collection = try TransactionCollection(
            name: "Reise", systemIconName: "tag",
            startDate: Date(timeIntervalSince1970: 1_780_000_000),
            endDateExclusive: Date(timeIntervalSince1970: 1_780_500_000),
            accountIDs: [account.id]
        )
        try await dependencies.transactionCollectionRepository.upsert([collection])
        let model = PocketsModel(dependencies: dependencies)
        await model.load()
        model.selectedCollectionID = collection.id

        let task = Task { await model.loadCandidates() }
        task.cancel()
        await task.value

        #expect(!model.isLoadingCandidates)
    }

    @Test("Analyse: ein abgebrochenes Laden lässt keinen Spinner stehen")
    func cancelledAnalyticsLoadResetsFlag() async throws {
        let dependencies = try makeDependencies()
        let model = AnalyticsModel(dependencies: dependencies)

        let task = Task { await model.load() }
        task.cancel()
        await task.value

        #expect(!model.isLoading)
    }
}
