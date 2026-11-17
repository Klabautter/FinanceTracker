#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import FinanceTracker

/// Widgets (Roadmap 10.4): Stand schreiben/lesen, aus echten Daten
/// berechnen und beide Widget-Inhalte rendern.
@MainActor
@Suite("WidgetSnapshot", .serialized)
struct WidgetSnapshotTests {
    private func temporaryStore() -> WidgetSnapshotStore {
        WidgetSnapshotStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetSnapshot-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("Schreiben und Lesen ergibt denselben Stand, Beträge exakt als Decimal")
    func roundTrip() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let snapshot = WidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            currency: "EUR",
            monthSpending: Decimal(string: "1234.56")!,
            availableUntilMonthEnd: Decimal(string: "-12.30")!,
            budgets: [.init(id: UUID(), name: "Lebensmittel", systemIconName: "cart", spent: 310, limit: 400, currency: "EUR")],
            hidesAmounts: true
        )
        try store.write(snapshot)
        #expect(store.read() == snapshot)
    }

    @Test("Unbekanntes Format oder kaputte Datei: kein Stand statt erfundener Zahlen")
    func rejectsUnknownFormat() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(store.read() == nil)
        var snapshot = WidgetSnapshot(updatedAt: Date(), currency: "EUR", monthSpending: 1, availableUntilMonthEnd: nil, budgets: [], hidesAmounts: false)
        snapshot.formatVersion = 99
        try store.write(snapshot)
        #expect(store.read() == nil)
        try Data("kaputt".utf8).write(to: store.fileURL)
        #expect(store.read() == nil)
    }

    @Test("Ohne App-Group-Berechtigung schreibt die App nichts")
    func noStoreWithoutEntitlement() {
        #expect(WidgetSnapshotStore.shared() == nil)
    }

    @Test("Stand wird wie die Übersicht berechnet")
    func snapshotFromDashboard() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let category = FinanceTracker.Category(name: "Lebensmittel", systemIconName: "cart")
        try await dependencies.categoryRepository.upsert([category])
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        var purchase = Transaction(
            accountID: account.id, source: .manual, status: .booked, kind: .purchase,
            amount: Money(amount: -42, currency: .eur), bookedAt: Date(),
            rawDescription: "Markt", merchantDisplayName: "Markt"
        )
        purchase.categoryID = category.id
        try await dependencies.transactionRepository.upsert([purchase])
        try await dependencies.budgetRepository.upsert([Budget(name: "Essen", amount: 100, currency: .eur, categoryIDs: [category.id])])

        let snapshot = try #require(await WidgetSnapshotPublisher.makeSnapshot(dependencies: dependencies, hidesAmounts: false))
        #expect(snapshot.monthSpending == 42)
        #expect(snapshot.currency == "EUR")
        let line = try #require(snapshot.budgets.first)
        #expect(line.name == "Essen")
        #expect(line.spent == 42)
        #expect(line.limit == 100)
    }

    @Test("Beide Widgets rendern hell, dunkel und mit verborgenen Beträgen")
    func rendersWidgets() throws {
        let gallery = FileManager.default.temporaryDirectory.appendingPathComponent("FinanceTrackerLayoutGallery", isDirectory: true)
        try FileManager.default.createDirectory(at: gallery, withIntermediateDirectories: true)
        let sample = WidgetSnapshot(
            updatedAt: Date(), currency: "EUR", monthSpending: 1_240, availableUntilMonthEnd: 860,
            budgets: [
                .init(id: UUID(), name: "Lebensmittel", systemIconName: "cart", spent: 310, limit: 400, currency: "EUR"),
                .init(id: UUID(), name: "Restaurants", systemIconName: "fork.knife", spent: 140, limit: 120, currency: "EUR")
            ],
            hidesAmounts: false
        )
        var hidden = sample
        hidden.hidesAmounts = true
        let cases: [(String, AnyView, CGSize)] = [
            ("widget-available", AnyView(AvailableWidgetContent(snapshot: sample)), CGSize(width: 170, height: 170)),
            ("widget-available-hidden", AnyView(AvailableWidgetContent(snapshot: hidden)), CGSize(width: 170, height: 170)),
            ("widget-available-empty", AnyView(AvailableWidgetContent(snapshot: nil)), CGSize(width: 170, height: 170)),
            ("widget-budgets", AnyView(BudgetsWidgetContent(snapshot: sample)), CGSize(width: 364, height: 170)),
            ("widget-budgets-hidden", AnyView(BudgetsWidgetContent(snapshot: hidden)), CGSize(width: 364, height: 170))
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, view, size) in cases {
                let renderer = ImageRenderer(content: view
                    .padding(16)
                    .frame(width: size.width, height: size.height)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.colorScheme, scheme))
                renderer.scale = 2
                let image = try #require(renderer.nsImage, "\(name) wurde nicht gerendert")
                let data = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
                try data.write(to: gallery.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        #expect(WidgetFormatting.amount(860, currency: "EUR", hidden: true) == "•••")
    }
}
#endif
