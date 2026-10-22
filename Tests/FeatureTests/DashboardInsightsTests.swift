import Foundation
import Testing

@testable import FinanceTracker

/// Fokus-Übersicht: Die Darstellungslogik liegt außerhalb der Views
/// und ist deshalb ohne SwiftUI prüfbar.
@Suite("DashboardInsights")
struct DashboardInsightsTests {

    private let calendar = Calendar(identifier: .gregorian)

    private func september() -> DateInterval {
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    private func day(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day))!
    }

    // MARK: - Tempo

    @Test("Rahmen kommt aus Forecast: verbraucht + noch verfügbar")
    func paceUsesForecastEnvelope() throws {
        // 300 verbraucht, 700 verfügbar → Rahmen 1000 → 30 %.
        let pace = try #require(DashboardInsights.pace(
            spent: 300,
            available: 700,
            budgetLimit: nil,
            interval: september(),
            now: day(16)
        ))

        #expect(pace.spentPercent == 30)
        // 15 von 30 Tagen vorbei = 50 %.
        #expect(pace.elapsedPercent == 50)
        #expect(pace.isUnderPace)
        #expect(!pace.isOverPace)
        #expect(pace.summary == "Langsamer als der Monat")
    }

    @Test("Ohne Forecast dienen die Budget-Limits als Bezug")
    func paceFallsBackToBudgetLimit() throws {
        let pace = try #require(DashboardInsights.pace(
            spent: 800,
            available: nil,
            budgetLimit: 1000,
            interval: september(),
            now: day(16)
        ))

        #expect(pace.spentPercent == 80)
        #expect(pace.isOverPace)
        #expect(pace.summary == "Schneller als der Monat")
    }

    @Test("Ohne Rahmen gibt es kein Tempo statt eines erfundenen Bezugs")
    func paceWithoutEnvelopeIsNil() {
        #expect(DashboardInsights.pace(
            spent: 500,
            available: nil,
            budgetLimit: nil,
            interval: september(),
            now: day(16)
        ) == nil)

        #expect(DashboardInsights.pace(
            spent: 500,
            available: 100,
            budgetLimit: nil,
            interval: nil,
            now: day(16)
        ) == nil)
    }

    @Test("Anteile bleiben zwischen 0 und 1 gekappt")
    func paceIsClamped() throws {
        // Überschreitung: verbraucht > Rahmen ist durch max(0,·) begrenzt.
        let pace = try #require(DashboardInsights.pace(
            spent: 2000,
            available: -500,
            budgetLimit: nil,
            interval: september(),
            now: day(40)
        ))

        #expect(pace.spentFraction == 1)
        #expect(pace.elapsedFraction == 1)
        #expect(!pace.isOverPace)
    }

    @Test("Gleichstand von Verbrauch und Zeit gilt als im Takt")
    func paceTolerance() throws {
        let pace = try #require(DashboardInsights.pace(
            spent: 500,
            available: 500,
            budgetLimit: nil,
            interval: september(),
            now: day(16)
        ))

        #expect(pace.summary == "Im Takt des Monats")
        #expect(!pace.isOverPace)
        #expect(!pace.isUnderPace)
    }

    // MARK: - Spektrum

    @Test("Spektrum-Anteile ergeben zusammen das Ganze")
    func spectrumFractionsSumToOne() {
        let segments = DashboardInsights.spectrum(from: [
            CategoryTotal(categoryID: UUID(), name: "Wohnen", amount: 500),
            CategoryTotal(categoryID: UUID(), name: "Essen", amount: 300),
            CategoryTotal(categoryID: UUID(), name: "Mobilität", amount: 200)
        ])

        #expect(segments.count == 3)
        #expect(segments.map(\.percent) == [50, 30, 20])
        #expect(abs(segments.reduce(0) { $0 + $1.fraction } - 1) < 0.0001)
    }

    @Test("Überzählige Bereiche werden zu genau einem Sammelsegment gebündelt")
    func spectrumAggregatesRemainder() throws {
        let items = (1...9).map { index in
            CategoryTotal(categoryID: UUID(), name: "K\(index)", amount: Decimal(10))
        }

        let segments = DashboardInsights.spectrum(from: items, maxSegments: 6)

        #expect(segments.count == 7)
        let last = try #require(segments.last)
        #expect(last.isAggregate)
        #expect(last.name == "Weitere")
        #expect(last.categoryID == nil)
        // 3 Restbereiche à 10 von 90 gesamt.
        #expect(last.amount == 30)
        #expect(abs(segments.reduce(0) { $0 + $1.fraction } - 1) < 0.0001)
    }

    @Test("Ohne Ausgaben bleibt das Spektrum leer statt durch Null zu teilen")
    func spectrumEmpty() {
        #expect(DashboardInsights.spectrum(from: []).isEmpty)
        #expect(DashboardInsights.spectrum(from: [
            CategoryTotal(categoryID: nil, name: "Leer", amount: 0)
        ]).isEmpty)
    }

    // MARK: - Zeitraum

    @Test("Tagesfortschritt zählt inklusive des laufenden Tages")
    func dayProgress() {
        #expect(DashboardInsights.dayProgressText(
            interval: september(), now: day(1), calendar: calendar
        ) == "Tag 1 von 30")

        #expect(DashboardInsights.dayProgressText(
            interval: september(), now: day(18), calendar: calendar
        ) == "Tag 18 von 30")

        #expect(DashboardInsights.dayProgressText(
            interval: september(), now: day(30), calendar: calendar
        ) == "Tag 30 von 30")
    }

    @Test("Tagesfortschritt bleibt im Zeitraum gekappt")
    func dayProgressClamped() {
        #expect(DashboardInsights.dayProgressText(
            interval: september(), now: day(45), calendar: calendar
        ) == "Tag 30 von 30")

        #expect(DashboardInsights.dayProgressText(
            interval: nil, now: day(5), calendar: calendar
        ) == nil)
    }
}

@Suite("DashboardLanguage")
struct DashboardLanguageTests {
    @Test("Zählangaben unterscheiden Einzahl und Mehrzahl")
    func bookings() {
        #expect(DashboardInsights.bookings(0) == "0 Buchungen")
        #expect(DashboardInsights.bookings(1) == "1 Buchung")
        #expect(DashboardInsights.bookings(2) == "2 Buchungen")
    }

    @Test("Verbform folgt der Zählangabe")
    func verbAgreement() {
        #expect(DashboardInsights.bookingsWere(1) == "1 Buchung wurde")
        #expect(DashboardInsights.bookingsWere(3) == "3 Buchungen wurden")
        #expect(DashboardInsights.bookingsWere(0) == "0 Buchungen wurden")
    }
}
