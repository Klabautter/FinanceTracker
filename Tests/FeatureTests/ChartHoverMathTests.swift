import Foundation
import Testing

@testable import FinanceTracker

/// Hover-Trefferzonen der Verlaufs-Charts (Washi/Elegant). Die Rechnung
/// liegt außerhalb der Views und ist deshalb ohne SwiftUI prüfbar.
@Suite("ChartHoverMath")
struct ChartHoverMathTests {

    @Test("Zeigerposition trifft die richtige Spalte")
    func columnIndex() {
        // 6 Spalten à 100 pt.
        #expect(ChartHoverMath.columnIndex(x: 0, width: 600, count: 6) == 0)
        #expect(ChartHoverMath.columnIndex(x: 99, width: 600, count: 6) == 0)
        #expect(ChartHoverMath.columnIndex(x: 100, width: 600, count: 6) == 1)
        #expect(ChartHoverMath.columnIndex(x: 550, width: 600, count: 6) == 5)
    }

    @Test("Rechter Rand fällt nicht aus dem gültigen Bereich")
    func columnIndexAtEdge() {
        // Ohne Klemmung ergäbe x == width den Index 6 (out of bounds).
        #expect(ChartHoverMath.columnIndex(x: 600, width: 600, count: 6) == 5)
    }

    @Test("Position außerhalb des Charts trifft keine Spalte")
    func columnIndexOutside() {
        #expect(ChartHoverMath.columnIndex(x: -1, width: 600, count: 6) == nil)
        #expect(ChartHoverMath.columnIndex(x: 601, width: 600, count: 6) == nil)
        #expect(ChartHoverMath.columnIndex(x: 10, width: 600, count: 0) == nil)
        #expect(ChartHoverMath.columnIndex(x: 10, width: 0, count: 6) == nil)
    }

    @Test("Spaltenmitte liegt mittig")
    func columnCenter() {
        #expect(ChartHoverMath.columnCenter(index: 0, width: 600, count: 6) == 50)
        #expect(ChartHoverMath.columnCenter(index: 5, width: 600, count: 6) == 550)
    }

    @Test("Tooltip bleibt innerhalb des Charts")
    func tooltipClamping() {
        // Links: würde über den Rand ragen → auf halbe Tooltipbreite gesetzt.
        #expect(ChartHoverMath.clampedTooltipX(center: 10, tooltipWidth: 190, chartWidth: 600) == 95)
        // Rechts: analog am anderen Rand.
        #expect(ChartHoverMath.clampedTooltipX(center: 590, tooltipWidth: 190, chartWidth: 600) == 505)
        // Mitte bleibt unverändert.
        #expect(ChartHoverMath.clampedTooltipX(center: 300, tooltipWidth: 190, chartWidth: 600) == 300)
    }

    @Test("Zu schmaler Chart zentriert den Tooltip statt ihn abzuschneiden")
    func tooltipWiderThanChart() {
        #expect(ChartHoverMath.clampedTooltipX(center: 40, tooltipWidth: 190, chartWidth: 100) == 50)
    }
}
