import AppKit
import Foundation
import Testing

@testable import FinanceTracker

/// WP13: Kuratierter Icon-Katalog: Integrität und Renderbarkeit.
@Suite("FinanceIconPickerCatalog")
struct FinanceIconPickerCatalogTests {

    @Test("Katalog ist nicht leer und frei von Duplikaten")
    func catalogIntegrity() {
        let catalog = FinanceIconPicker.catalog
        #expect(catalog.count >= 24)
        let symbols = catalog.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("Jeder Eintrag hat ein verständliches Label und Keywords")
    func labelsAndKeywords() {
        for entry in FinanceIconPicker.catalog {
            #expect(!entry.label.isEmpty)
            #expect(!entry.keywords.isEmpty)
        }
    }

    @Test("Jedes Katalog-Symbol existiert in SF Symbols (macOS)")
    func allSymbolsRender() {
        for entry in FinanceIconPicker.catalog {
            let image = NSImage(
                systemSymbolName: entry.symbol,
                accessibilityDescription: entry.label
            )
            #expect(image != nil, "SF Symbol '\(entry.symbol)' existiert nicht")
        }
    }

    @Test("Standard-Fallback 'tag' ist im Katalog")
    func fallbackInCatalog() {
        #expect(FinanceIconPicker.catalog.contains { $0.symbol == "tag" })
    }
}
