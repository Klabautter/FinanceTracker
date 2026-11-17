import SwiftUI

/// Inhalte der Widgets (Roadmap 10.4). Reine SwiftUI-Ansichten ohne
/// WidgetKit, damit App-Tests sie rendern können; die Widget-Erweiterung
/// legt nur Rahmen und Hintergrund darum. Diese Datei gehört zur App und
/// zur Widget-Erweiterung.
enum WidgetFormatting {
    static func amount(_ value: Decimal, currency: String, hidden: Bool) -> String {
        hidden ? "•••" : value.formatted(.currency(code: currency).precision(.fractionLength(0)))
    }
}

/// Klein: „Verfügbar bis Monatsende“ und die bisherigen Ausgaben.
struct AvailableWidgetContent: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Verfügbar", systemImage: "calendar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let snapshot {
                if let available = snapshot.availableUntilMonthEnd {
                    Text(WidgetFormatting.amount(available, currency: snapshot.currency, hidden: snapshot.hidesAmounts))
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .foregroundStyle(available < 0 ? Color.red : Color.primary)
                    Text("bis Monatsende")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Für eine Prognose fehlen noch Daten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("Ausgaben \(WidgetFormatting.amount(snapshot.monthSpending, currency: snapshot.currency, hidden: snapshot.hidesAmounts))")
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                Text(snapshot.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Spacer(minLength: 0)
                Text("FinanceTracker öffnen, um das Widget zu füllen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// Mittel: die drei Budgets, die am meisten Aufmerksamkeit brauchen.
struct BudgetsWidgetContent: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Budgets", systemImage: "chart.pie")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let snapshot, !snapshot.budgets.isEmpty {
                ForEach(snapshot.budgets) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Label(line.name, systemImage: line.systemIconName)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("\(WidgetFormatting.amount(line.spent, currency: line.currency, hidden: snapshot.hidesAmounts)) / \(WidgetFormatting.amount(line.limit, currency: line.currency, hidden: snapshot.hidesAmounts))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        WidgetProgressBar(fraction: line.fraction)
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
            } else if snapshot != nil {
                Spacer(minLength: 0)
                Text("Noch keine Budgets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 0)
                Text("FinanceTracker öffnen, um das Widget zu füllen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Schlichter Fortschrittsbalken: rot über dem Limit, orange ab 85 %.
struct WidgetProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(fraction > 1 ? Color.red : fraction >= 0.85 ? Color.orange : Color.green)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}
