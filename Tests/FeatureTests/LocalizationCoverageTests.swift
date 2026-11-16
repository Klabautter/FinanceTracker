import Foundation
import Testing

/// Jeder UI-Text im Katalog braucht einen englischen Eintrag, sonst sehen
/// englische Nutzer Deutsch. Neue Texte landen beim Bauen automatisch im
/// Katalog (Compiler-Extraktion); dieser Test hält sie nicht ohne
/// Übersetzung durch.
@Suite("LocalizationCoverage")
struct LocalizationCoverageTests {
    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FinanceTracker/Resources/Localizable.xcstrings")
    }

    @Test("Jeder Katalog-Eintrag hat eine englische Übersetzung")
    func everyStringHasEnglish() throws {
        let data = try Data(contentsOf: Self.catalogURL)
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        let missing = strings.compactMap { key, entry -> String? in
            guard !key.isEmpty else { return nil }
            if entry["shouldTranslate"] as? Bool == false { return nil }
            if entry["extractionState"] as? String == "stale" { return nil }
            let localizations = entry["localizations"] as? [String: Any]
            return localizations?["en"] == nil ? key : nil
        }
        #expect(missing.isEmpty, "Ohne Englisch: \(missing.sorted().prefix(20).joined(separator: " | "))")
    }
}
