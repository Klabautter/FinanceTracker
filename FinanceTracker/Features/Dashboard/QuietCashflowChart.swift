import Charts
import SwiftUI

/// Ruhiges Verlaufs-Chart für Darstellungen ohne Signalfarben.
///
/// Bewusst eigenständig statt `MonthlyCashflowChart`: kein Gitternetz, keine
/// Y-Achse, keine Signalfarben, für Darstellungen, die mit dem Chart nicht
/// konkurrieren wollen. Interaktion identisch: Klick öffnet den Monat.
struct QuietCashflowChart: View {
    /// Gedämpfte Palette: wertbasiert statt Signalfarben. Unterscheidbar
    /// über Helligkeit UND Farbton (nicht nur Opazität).
    static let spendingInk = Color.primary.opacity(0.78)
    static let incomeInk = AppTone.positive.foregroundColor.opacity(0.45)

    let points: [MonthlyCashflowPoint]
    let currency: CurrencyCode
    var onMonthTap: ((DateInterval) -> Void)?
    var amountsHidden: Bool = false

    private var maxValue: Decimal {
        points.reduce(Decimal(0)) { Swift.max($0, Swift.max($1.income, $1.spending)) }
    }

    var body: some View {
        if points.isEmpty {
            Text("Noch kein Verlauf vorhanden.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                GeometryReader { geo in
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(points) { point in
                            column(for: point, height: geo.size.height)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 120)

                Rectangle()
                    .fill(.primary.opacity(0.16))
                    .frame(height: 1)

                HStack(spacing: 0) {
                    ForEach(points) { point in
                        Text(AppDateFormatter.monthYear(point.monthStart).prefix(3).uppercased())
                            .font(.system(size: 9, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                ChartAccessibility.monthlyCashflowSummary(
                    points: points,
                    currency: currency,
                    amountsHidden: amountsHidden
                )
            )
        }
    }

    /// Zwei schmale Säulen pro Monat: Einnahmen hell, Ausgaben dunkel.
    /// Unterscheidbar über Helligkeit UND Farbton (nicht nur Opazität).
    private func column(for point: MonthlyCashflowPoint, height: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            bar(value: point.income, height: height, color: Self.incomeInk)
            bar(value: point.spending, height: height, color: Self.spendingInk)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { open(point) }
        .help(AppDateFormatter.monthYear(point.monthStart))
    }

    private func bar(value: Decimal, height: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: 10, height: barHeight(value, available: height))
    }

    private func barHeight(_ value: Decimal, available: CGFloat) -> CGFloat {
        guard maxValue > 0, value > 0 else { return 1 }
        let ratio = NSDecimalNumber(decimal: value / maxValue).doubleValue
        guard ratio.isFinite else { return 1 }
        return Swift.max(1, available * Swift.min(Swift.max(ratio, 0), 1))
    }

    private func open(_ point: MonthlyCashflowPoint) {
        guard let onMonthTap else { return }
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .month, value: 1, to: point.monthStart) else { return }
        onMonthTap(DateInterval(start: point.monthStart, end: end))
    }
}
