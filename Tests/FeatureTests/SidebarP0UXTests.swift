import Foundation
import Testing

@testable import FinanceTracker

/// P0 UX: Import ist über Konten & Verbindungen erreichbar; die Prüfliste
/// ist über die Command Palette und den macOS-Befehl erreichbar. Der Inspector
/// öffnet nie automatisch.
@MainActor
@Suite("SidebarP0UX")
struct SidebarP0UXTests {

    @Test("AppSection-Titel entsprechen den kanonischen Navigationsnamen")
    func sectionTitles() {
        #expect(AppSection.recurring.title == "Wiederkehrend")
        #expect(AppSection.pockets.title == "Sammlungen")
        #expect(AppSection.accounts.title == "Konten & Verbindungen")
        #expect(AppSection.categories.title == "Kategorien & Regeln")
    }

    @Test("Jede Sektion hat ein SF-Symbol")
    func sectionIcons() {
        for section in AppSection.allCases {
            #expect(!section.systemImage.isEmpty, "Kein Icon für \(section)")
        }
    }

    @Test("Sidebar gruppiert alle Sektionen nach Alltag, Planung, Organisation und Daten")
    func sidebarGroupsWithoutEingang() {
        let groups = AppSection.sidebarGroups
        let all = groups.flatMap(\.sections)
        #expect(Set(all).count == all.count, "Sektion doppelt vergeben")
        #expect(Set(all) == Set(AppSection.allCases), "Nicht alle Sektionen in der Sidebar")
        #expect(groups.map(\.title) == ["Alltag", "Planung", "Organisation", "Daten"])
        #expect(groups.map(\.sections) == [
            [.overview, .transactions, .analytics],
            [.budgets, .recurring],
            [.pockets, .categories],
            [.accounts],
        ])
        #expect(AppSection.allCases.count == 8, "Import/Prüfliste/Tags sind keine Sektionen mehr")
    }

    @Test("⌘1…⌘9 folgen der Sidebar-Reihenfolge und decken alle Bereiche ab")
    func shortcutSectionsFollowSidebarOrder() {
        let shortcuts = AppSection.shortcutSections
        #expect(shortcuts.count <= 9)
        #expect(shortcuts == AppSection.sidebarGroups.flatMap(\.sections))
        #expect(shortcuts.first == .overview)
        #expect(Set(shortcuts) == Set(AppSection.allCases))
    }

    @Test("Command Palette führt Sektionen und Prüfliste mit aktuellem Status")
    func paletteListsSectionsAndReviewQueue() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let model = CommandPaletteModel(dependencies: dependencies, privacyState: PrivacyPresentationState())
        let entries = model.navigationEntries(reviewCount: 4)
        let titles = Set(entries.map(\.title))
        #expect(Set(AppSection.allCases.map(\.title)).isSubset(of: titles))
        #expect(titles.contains("Prüfen"))
        #expect(entries.contains { $0.kind == .settings && $0.title == "Einstellungen" })
        #expect(!titles.contains("Import"))
        #expect(!titles.contains("Prüfliste"))
        let queueEntry = try #require(entries.first { $0.kind == .reviewQueue })
        #expect(queueEntry.subtitle == "4 offen")
    }
}

/// P0 (#31): Inspector-Sichtbarkeit: Auswahlwechsel öffnet/schließt nie,
/// nur explizite Aktionen (Doppelklick, Info-Button, ⌘I, Deep-Link).
@Suite("TransactionInspectorState")
struct TransactionInspectorStateTests {
    @Test("Startet geschlossen")
    func startsClosed() {
        #expect(TransactionInspectorState().isPresented == false)
    }

    @Test("Auswahlwechsel öffnet nicht und schließt nicht")
    func selectionChangeNeverToggles() {
        var state = TransactionInspectorState()
        state.selectionDidChange()
        #expect(state.isPresented == false)

        state.openExplicitly()
        state.selectionDidChange()
        #expect(state.isPresented == true, "Leeren der Auswahl schließt nicht zwangsläufig")
    }

    @Test("Explizite Aktionen steuern die Sichtbarkeit")
    func explicitActions() {
        var state = TransactionInspectorState()
        state.openExplicitly()
        #expect(state.isPresented == true)
        state.toggle()
        #expect(state.isPresented == false)
        state.toggle()
        #expect(state.isPresented == true)
        state.close()
        #expect(state.isPresented == false)
    }
}
