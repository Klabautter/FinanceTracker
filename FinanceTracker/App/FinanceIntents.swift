import AppIntents
import Foundation

/// Zahlen des laufenden Monats für Kurzbefehle und Siri, berechnet wie auf
/// der Übersicht (dieselbe Cashflow-Regel, Umrechnung und Prognose).
struct MonthSummary: Sendable {
    let spending: Decimal
    let available: Decimal?
    let currency: CurrencyCode

    @MainActor
    static func current(dependencies: AppDependencies) async throws -> MonthSummary {
        let model = DashboardModel(dependencies: dependencies)
        await model.load()
        guard let snapshot = model.snapshot else {
            throw FinanceIntentError.noData
        }
        return MonthSummary(
            spending: snapshot.totalSpending,
            available: model.forecast?.availableAmount,
            currency: dependencies.baseCurrency
        )
    }

    func formatted(_ value: Decimal) -> String {
        value.formatted(.currency(code: currency.rawValue))
    }
}

enum FinanceIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noData

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noData: "Für diesen Monat gibt es noch keine Buchungen."
        }
    }
}

struct MonthSpendingIntent: AppIntent {
    static let title: LocalizedStringResource = "Ausgaben diesen Monat"
    static let description = IntentDescription("Sagt, wie viel du im laufenden Monat ausgegeben hast.")

    @Dependency private var dependencies: AppDependencies

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let summary = try await MonthSummary.current(dependencies: dependencies)
        let text = summary.formatted(summary.spending)
        return .result(
            value: NSDecimalNumber(decimal: summary.spending).doubleValue,
            dialog: "Diesen Monat hast du bisher \(text) ausgegeben."
        )
    }
}

struct AvailableUntilMonthEndIntent: AppIntent {
    static let title: LocalizedStringResource = "Verfügbar bis Monatsende"
    static let description = IntentDescription("Sagt, wie viel laut Prognose bis zum Monatsende verfügbar ist.")

    @Dependency private var dependencies: AppDependencies

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = try await MonthSummary.current(dependencies: dependencies)
        guard let available = summary.available else {
            return .result(dialog: "Für eine Prognose fehlen noch Daten, zum Beispiel ein Gehalt oder Budgets.")
        }
        return .result(dialog: "Bis zum Monatsende sind noch etwa \(summary.formatted(available)) verfügbar.")
    }
}

struct FinanceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: MonthSpendingIntent(),
            phrases: ["Wie viel habe ich diesen Monat mit \(.applicationName) ausgegeben", "Ausgaben in \(.applicationName)"],
            shortTitle: "Ausgaben diesen Monat",
            systemImageName: "chart.bar"
        )
        AppShortcut(
            intent: AvailableUntilMonthEndIntent(),
            phrases: ["Wie viel ist in \(.applicationName) noch verfügbar", "Verfügbar bis Monatsende in \(.applicationName)"],
            shortTitle: "Noch verfügbar",
            systemImageName: "calendar"
        )
    }
}
