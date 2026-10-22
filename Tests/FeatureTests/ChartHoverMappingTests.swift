import Foundation
import Testing

@testable import FinanceTracker

/// Reine Mapping-Logik der Chart-Hover-Interaktion (Winkel → Pie-Segment,
/// Datum → Cashflow-Monat) ohne UI-Durchklick.
@Suite("ChartHoverMapping")
struct ChartHoverMappingTests {
    // MARK: - CategoryPieChart.sliceIndex

    @Test("Pie: Winkel 0° trifft das erste Segment (12 Uhr)")
    func angleZeroHitsFirstSlice() {
        #expect(CategoryPieChart.sliceIndex(atAngleDegrees: 0, fractions: [0.5, 0.5]) == 0)
    }

    @Test("Pie: Winkel mitten im zweiten Segment")
    func angleInSecondSlice() {
        // 270° = 75 % der Fläche → zweites Segment bei 50/50
        #expect(CategoryPieChart.sliceIndex(atAngleDegrees: 270, fractions: [0.5, 0.5]) == 1)
    }

    @Test("Pie: Grenzfall gehört zum nachfolgenden Segment")
    func boundaryBelongsToNextSlice() {
        // 180° = exakt 50 %, die Grenze zwischen Segment 1 und 2
        #expect(CategoryPieChart.sliceIndex(atAngleDegrees: 180, fractions: [0.5, 0.5]) == 1)
    }

    @Test("Pie: kurz vor 360° fällt auf das letzte Segment zurück")
    func wraparoundHitsLastSlice() {
        #expect(CategoryPieChart.sliceIndex(atAngleDegrees: 359.9, fractions: [0.5, 0.3, 0.2]) == 2)
    }

    @Test("Pie: leere Anteile oder Gesamtsumme 0 liefern nil")
    func degenerateFractionsReturnNil() {
        #expect(CategoryPieChart.sliceIndex(atAngleDegrees: 45, fractions: []) == nil)
        #expect(CategoryPieChart.sliceIndex(atAngleDegrees: 45, fractions: [0, 0]) == nil)
    }

    // MARK: - MonthlyCashflowChart.nearestPoint

    @Test("Cashflow: nächstliegender Monat wird gewählt")
    func nearestPointIsChosen() {
        let calendar = Calendar(identifier: .gregorian)
        func day(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
        }
        let points = [
            MonthlyCashflowPoint(monthStart: day(1, 1), income: 100, spending: 10),
            MonthlyCashflowPoint(monthStart: day(2, 1), income: 200, spending: 20)
        ]

        // 5. Jan liegt nahe am Januar-Punkt.
        #expect(MonthlyCashflowChart.nearestPoint(to: day(1, 5), in: points)?.income == 100)
        // 25. Jan liegt näher am Februar-Punkt.
        #expect(MonthlyCashflowChart.nearestPoint(to: day(1, 25), in: points)?.income == 200)
        #expect(MonthlyCashflowChart.nearestPoint(to: day(1, 15), in: []) == nil)
    }
}
