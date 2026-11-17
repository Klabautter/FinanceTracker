import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Berechnet den Widget-Stand wie die Übersicht (dieselben Zahlen wie
/// Kurzbefehle und Dashboard) und legt ihn im App-Group-Ordner ab.
@MainActor
enum WidgetSnapshotPublisher {
    static func makeSnapshot(
        dependencies: AppDependencies,
        hidesAmounts: Bool,
        now: Date = Date()
    ) async -> WidgetSnapshot? {
        let model = DashboardModel(dependencies: dependencies)
        await model.load()
        guard let analytics = model.snapshot else { return nil }
        let budgets = model.attentionBudgets.prefix(3).map { progress in
            WidgetSnapshot.BudgetLine(
                id: progress.budget.id,
                name: progress.budget.name,
                systemIconName: progress.budget.systemIconName,
                spent: progress.spent,
                limit: progress.effectiveLimit,
                currency: progress.currency.rawValue
            )
        }
        return WidgetSnapshot(
            updatedAt: now,
            currency: dependencies.baseCurrency.rawValue,
            monthSpending: analytics.totalSpending,
            availableUntilMonthEnd: model.forecast?.availableAmount,
            budgets: Array(budgets),
            hidesAmounts: hidesAmounts
        )
    }

    /// Schreibt den Stand und lässt die Widgets neu zeichnen. Ohne App-Group
    /// (Debug-Build ohne Team-ID) passiert nichts.
    static func publish(dependencies: AppDependencies, hidesAmounts: Bool, store: WidgetSnapshotStore? = .shared()) async {
        guard let store,
              let snapshot = await makeSnapshot(dependencies: dependencies, hidesAmounts: hidesAmounts) else { return }
        do {
            try store.write(snapshot)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        } catch {
            // Die Widgets zeigen dann weiter den letzten Stand mit Datum.
        }
    }
}
