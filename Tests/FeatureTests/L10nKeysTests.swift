import Testing

@testable import FinanceTracker

/// P2 L10n-Anbruch: Kern-Strings laufen über `String(localized:)` mit
/// deutschem Basis-String als Key, ohne Katalog fällt die API auf den Key
/// zurück, daher dokumentieren diese Tests die de-Basis (Muster für den
/// schrittweisen Ausbau, kein Big-Bang).
@Suite("L10nKeys")
struct L10nKeysTests {
    @Test("Sidebar-Titel vorhanden (de-Basis)")
    func sidebarTitlesPresent() {
        let titles: [(AppSection, String)] = [
            (.overview, "Übersicht"),
            (.transactions, "Transaktionen"),
            (.analytics, "Analyse"),
            (.budgets, "Budgets"),
            (.pockets, "Sammlungen"),
            (.accounts, "Konten & Verbindungen"),
            (.categories, "Kategorien & Regeln"),
            (.recurring, "Wiederkehrend"),
        ]
        for (section, expected) in titles {
            #expect(section.title == expected, "Titel für \(section.rawValue)")
        }
    }

    @Test("Sidebar-Gruppen vorhanden (de-Basis)")
    func sidebarGroupsPresent() {
        #expect(AppSection.sidebarGroups.map(\.title) == ["Alltag", "Planung", "Organisation", "Daten"])
    }

    @Test("Währungsangebot enthält EUR/USD/GBP und mehr")
    func offeredCurrenciesSuperset() {
        #expect(CurrencyCode.offered.contains(.eur))
        #expect(CurrencyCode.offered.contains(.usd))
        #expect(CurrencyCode.offered.contains(.gbp))
        #expect(CurrencyCode.offered.count > 3)
        #expect(Set(CurrencyCode.offered.map(\.rawValue)).count == CurrencyCode.offered.count)
    }
}
