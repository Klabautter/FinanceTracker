#if DEBUG
import Foundation
import Testing

@testable import FinanceTracker

/// Die Preview-/Render-Daten müssen jeden Abschnitt der Übersicht füllen.
/// Sonst wirken Darstellungen leer, obwohl sie korrekt sind, genau das
/// war vor dem Nachziehen von Budgets und Fixkosten der Fall.
@MainActor
@Suite("PreviewDataCompleteness")
struct PreviewDataCompletenessTests {

    @Test("Preview-Store enthält Konten, Kategorien, Budgets und Fixkosten")
    func storeIsPopulated() async throws {
        let dependencies = PreviewDependencies.dependencies()

        let accounts = try await dependencies.accountRepository.accounts()
        let categories = try await dependencies.categoryRepository.categories()
        let budgets = try await dependencies.budgetRepository.budgets()
        let commitments = try await dependencies.recurringCommitmentRepository.commitments()

        #expect(!accounts.isEmpty)
        #expect(!categories.isEmpty)
        #expect(!budgets.isEmpty, "Ohne Budgets bleiben Budget-Abschnitt und Tempo leer")
        #expect(!commitments.isEmpty, "Ohne Fixkosten kann keine Prognose entstehen")
    }

    @Test("Dashboard füllt alle Abschnitte der Übersicht")
    func dashboardSectionsArePopulated() async throws {
        let model = DashboardModel(dependencies: PreviewDependencies.dependencies())
        await model.load()

        let snapshot = try #require(model.snapshot)
        #expect(snapshot.totalSpending > 0)
        #expect(!snapshot.spendingByCategory.isEmpty)
        #expect(!snapshot.spendingByMerchant.isEmpty)
        #expect(!model.monthlyPoints.isEmpty)
        #expect(!model.recentTransactions.isEmpty)
        #expect(!model.budgetProgresses.isEmpty, "Budget-Abschnitt bliebe sonst unsichtbar")
        #expect(model.previousSnapshot != nil, "Ohne Vormonat fehlt die Trendangabe")
    }
}
#endif
