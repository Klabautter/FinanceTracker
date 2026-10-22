import SwiftUI

@MainActor
enum ChartAccessibility {
    /// Chart-Zusammenfassungen dürfen bei Privacy ON keine echten Beträge
    /// weitergeben. Der Zustand kommt als Bool (kein Features-Import im
    /// DesignSystem).
    static func monthlyCashflowSummary(
        points: [MonthlyCashflowPoint],
        currency: CurrencyCode,
        amountsHidden: Bool = false
    ) -> String {
        guard !points.isEmpty else { return String(localized: "Kein monatlicher Cashflow vorhanden.") }

        let first = AppDateFormatter.monthYear(points[0].monthStart)
        let last = AppDateFormatter.monthYear(points[points.count - 1].monthStart)
        let range = String(localized: "Monatlicher Cashflow von \(first) bis \(last) über \(points.count) Monate.")

        guard !amountsHidden else {
            return range + " " + String(localized: "Beträge verborgen.")
        }

        let totalIncome = points.reduce(into: Decimal(0)) { $0 += $1.income }
        let totalSpending = points.reduce(into: Decimal(0)) { $0 += $1.spending }

        let income = MoneyFormatter.decimalString(totalIncome, currency: currency)
        let spending = MoneyFormatter.decimalString(totalSpending, currency: currency)
        return range + " " + String(localized: "Einnahmen \(income), Ausgaben \(spending).")
    }

    static func categoryBreakdownSummary(
        items: [CategoryTotal],
        currency: CurrencyCode,
        amountsHidden: Bool = false
    ) -> String {
        guard !items.isEmpty else { return String(localized: "Keine Kategorien-Ausgaben vorhanden.") }
        guard !amountsHidden else {
            let names = items.prefix(5).map(\.name).joined(separator: ", ")
            return String(localized: "Ausgaben nach Kategorie. Top: \(names). Beträge verborgen.")
        }
        let top = items.prefix(5)
            .map { "\($0.name): \(MoneyFormatter.decimalString($0.amount, currency: currency))" }
            .joined(separator: ", ")
        return String(localized: "Ausgaben nach Kategorie. Top: \(top).")
    }

    static func pieSummary(
        items: [CategoryTotal],
        currency: CurrencyCode,
        amountsHidden: Bool = false
    ) -> String {
        categoryBreakdownSummary(items: items, currency: currency, amountsHidden: amountsHidden)
    }
}

extension View {
    @ViewBuilder
    func chartAccessibilitySummary(_ summary: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
    }
}
