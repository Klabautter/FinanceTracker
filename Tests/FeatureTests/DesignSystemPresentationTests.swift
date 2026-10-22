import Testing

@testable import FinanceTracker

@Suite("Design-System-Präsentationsrollen")
struct DesignSystemPresentationTests {
    @Test("Jede semantische Rolle hat ein eindeutiges Symbol und einen Accessibility-Präfix")
    func semanticToneMetadataIsComplete() {
        let symbols = Set(AppTone.allCases.map(\.defaultSystemImage))
        let prefixes = Set(AppTone.allCases.map(\.accessibilityPrefix))

        #expect(symbols.count == AppTone.allCases.count)
        #expect(prefixes.count == AppTone.allCases.count)
        #expect(AppTone.positive.accessibilityPrefix == "Erfolgreich")
        #expect(AppTone.warning.accessibilityPrefix == "Warnung")
        #expect(AppTone.critical.accessibilityPrefix == "Fehler")
        #expect(AppTone.information.accessibilityPrefix == "Information")
    }

    @Test("MetricStrip übernimmt Label als stabile ID, erlaubt aber explizite IDs")
    func metricStripItemIdentity() {
        let inferred = MetricStripItem(label: "Verfügbar", value: "120 €")
        let explicit = MetricStripItem(
            id: "available-balance",
            label: "Verfügbar",
            value: "120 €",
            caption: "Heute",
            tone: .positive
        )

        #expect(inferred.id == "Verfügbar")
        #expect(inferred.tone == .neutral)
        #expect(explicit.id == "available-balance")
        #expect(explicit.caption == "Heute")
        #expect(explicit.tone == .positive)
    }
}
