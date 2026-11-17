import SwiftUI
import WidgetKit

/// Widget-Erweiterung (Roadmap 10.4): liest nur den Stand, den die App in
/// den gemeinsamen App-Group-Ordner schreibt (`WidgetSnapshotStore`).
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? .placeholder : WidgetSnapshotStore.shared()?.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.shared()?.read())
        // Die App stößt nach jeder Änderung ein Neuladen an; stündlich nur,
        // damit die relative Zeitangabe stimmt.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3_600))))
    }
}

struct AvailableWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "de.klabautter.FinanceTracker.available", provider: SnapshotProvider()) { entry in
            AvailableWidgetContent(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Verfügbar")
        .description("Was laut Prognose bis Monatsende verfügbar ist.")
        .supportedFamilies([.systemSmall])
    }
}

struct BudgetsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "de.klabautter.FinanceTracker.budgets", provider: SnapshotProvider()) { entry in
            BudgetsWidgetContent(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Budgets")
        .description("Die Budgets, die gerade am meisten Aufmerksamkeit brauchen.")
        .supportedFamilies([.systemMedium])
    }
}

@main
struct FinanceWidgets: WidgetBundle {
    var body: some Widget {
        AvailableWidget()
        BudgetsWidget()
    }
}

extension WidgetSnapshot {
    /// Beispielstand für die Widget-Galerie (keine echten Daten).
    static let placeholder = WidgetSnapshot(
        updatedAt: Date(),
        currency: "EUR",
        monthSpending: 1_240,
        availableUntilMonthEnd: 860,
        budgets: [
            .init(id: UUID(), name: "Lebensmittel", systemIconName: "cart", spent: 310, limit: 400, currency: "EUR"),
            .init(id: UUID(), name: "Restaurants", systemIconName: "fork.knife", spent: 140, limit: 120, currency: "EUR"),
            .init(id: UUID(), name: "Freizeit", systemIconName: "figure.walk", spent: 60, limit: 150, currency: "EUR")
        ],
        hidesAmounts: false
    )
}
