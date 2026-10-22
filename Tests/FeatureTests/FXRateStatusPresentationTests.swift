import Foundation
import Testing

@testable import FinanceTracker

@Suite("FX-Statuszeile (Präsentation)")
struct FXRateStatusPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21

    private func snapshot(
        source: FXRateSnapshot.Source,
        quoteAgeDays: Int?,
        isStale: Bool = false,
        refreshFailed: Bool = false
    ) -> FXRateSnapshot {
        FXRateSnapshot(
            eurPerUnit: [.usd: 0.92],
            quoteDate: quoteAgeDays.map { now.addingTimeInterval(-Double($0) * 86_400) },
            fetchedAt: nil,
            source: source,
            isStale: isStale,
            refreshFailed: refreshFailed
        )
    }

    @Test("Frischer Kurs ist neutral, auch wenn ein Refresh fehlschlug")
    func freshRateIsNeutral() {
        let snapshot = snapshot(source: .cache, quoteAgeDays: 3, refreshFailed: true)
        #expect(FXRateStatusPresentation.isWarning(snapshot, now: now) == false)
        let text = FXRateStatusPresentation.text(for: snapshot, now: now)
        #expect(text.hasPrefix("EZB-Referenzkurs aus Cache · Stand "))
        #expect(!text.contains("fehlgeschlagen"))
        #expect(!text.contains("veraltet"))
    }

    @Test("Kurs älter als 30 Tage wird zur Warnung inklusive Refresh-Fehler")
    func oldRateWarns() {
        let snapshot = snapshot(source: .live, quoteAgeDays: 31, refreshFailed: true)
        #expect(FXRateStatusPresentation.isWarning(snapshot, now: now))
        let text = FXRateStatusPresentation.text(for: snapshot, now: now)
        #expect(text.hasPrefix("Kurs veraltet · EZB-Referenzkurs"))
        #expect(text.hasSuffix("Aktualisierung fehlgeschlagen"))
        #expect(FXRateStatusPresentation.systemImage(for: snapshot, now: now) == "exclamationmark.triangle")
    }

    @Test("Explizit veralteter Kurs warnt unabhängig vom Datum")
    func staleFlagWarns() {
        let snapshot = snapshot(source: .live, quoteAgeDays: 1, isStale: true)
        #expect(FXRateStatusPresentation.isWarning(snapshot, now: now))
    }

    @Test("Statischer Fallback nutzt das Referenzdatum und warnt erst nach 30 Tagen")
    func fallbackUsesReferenceDate() {
        let snapshot = snapshot(source: .fallback, quoteAgeDays: nil)
        let reference = CurrencyConverter.referenceEURQuoteDate
        #expect(FXRateStatusPresentation.quoteDate(for: snapshot) == reference)
        #expect(FXRateStatusPresentation.isWarning(snapshot, now: reference.addingTimeInterval(10 * 86_400)) == false)
        #expect(FXRateStatusPresentation.isWarning(snapshot, now: reference.addingTimeInterval(40 * 86_400)))
        #expect(FXRateStatusPresentation.text(for: snapshot, now: reference).hasPrefix("Statischer Richtkurs · Stand "))
    }

    @Test("Detailansicht nennt Refresh-Fehler immer")
    func detailedAlwaysMentionsRefreshFailure() {
        let snapshot = snapshot(source: .cache, quoteAgeDays: 2, refreshFailed: true)
        let text = FXRateStatusPresentation.text(for: snapshot, now: now, detailed: true)
        #expect(text.hasSuffix("Aktualisierung fehlgeschlagen"))
    }
}
