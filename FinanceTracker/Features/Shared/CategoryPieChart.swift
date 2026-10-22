import Charts
import SwiftUI

/// Ein Segment des Kategorie-Pie-Charts.
struct CategoryPieSlice: Identifiable, Equatable {
    let id: String
    let name: String
    let amount: Decimal
    let color: Color
}

/// Donut-Pie der Ausgaben je Kategorie (Produkt-Wunsch 29.08.2026) mit
/// Hover-Tooltip: exakter Betrag + Anteil in Prozent pro Segment.
/// Die Geometrie-Auflösung (Winkel → Segment) ist als reine statische
/// Funktion getestet (`sliceIndex(atAngleDegrees:fractions:)`).
struct CategoryPieChart: View {
    let slices: [CategoryPieSlice]
    let currency: CurrencyCode

    @State private var hoveredIndex: Int?
    @State private var hoverLocation: CGPoint = .zero
    @Environment(PrivacyPresentationState.self) private var privacyState

    private var totalAmount: Decimal {
        slices.reduce(into: Decimal(0)) { $0 += $1.amount }
    }

    private var fractions: [Double] {
        let total = NSDecimalNumber(decimal: totalAmount).doubleValue
        guard total > 0 else { return slices.map { _ in 0 } }
        return slices.map { NSDecimalNumber(decimal: $0.amount).doubleValue / total }
    }

    var body: some View {
        Chart {
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                SectorMark(
                    angle: .value("Anteil", NSDecimalNumber(decimal: slice.amount).doubleValue),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.2
                )
                .cornerRadius(3)
                .foregroundStyle(slice.color)
                .opacity(opacity(at: index))
            }
        }
        .chartBackground { proxy in
            GeometryReader { geometry in
                let frame = proxy.plotFrame.map { geometry[$0] }
                    ?? CGRect(origin: .zero, size: geometry.size)
                VStack(spacing: 0) {
                    Text("Gesamt")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(amountText(totalAmount))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .position(x: frame.midX, y: frame.midY)
                .accessibilityHidden(true)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let frame = proxy.plotFrame.map { geometry[$0] }
                    ?? CGRect(origin: .zero, size: geometry.size)
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            updateHover(at: location, plotFrame: frame, containerSize: geometry.size)
                        case .ended:
                            hoveredIndex = nil
                        }
                    }
                if let hoveredIndex, slices.indices.contains(hoveredIndex) {
                    tooltip(for: slices[hoveredIndex])
                        .position(
                            x: clamp(hoverLocation.x, min: 105, max: max(105, geometry.size.width - 105)),
                            y: clamp(hoverLocation.y + 6, min: 42, max: max(42, geometry.size.height - 34))
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .chartAccessibilitySummary(accessibilitySummary)
        .accessibilityRepresentation {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(slices) { slice in
                    Text("\(slice.name): \(amountText(slice.amount)), \(percentText(slice.amount))")
                }
            }
        }
    }

    // MARK: - Hover

    private func updateHover(at location: CGPoint, plotFrame: CGRect, containerSize: CGSize) {
        let center = CGPoint(x: plotFrame.midX, y: plotFrame.midY)
        let dx = Double(location.x - center.x)
        let dy = Double(location.y - center.y)
        let radius = Double(min(plotFrame.width, plotFrame.height) / 2)
        guard radius > 0, (dx * dx + dy * dy).squareRoot() <= radius else {
            hoveredIndex = nil
            return
        }
        // 0° = 12 Uhr, im Uhrzeigersinn (SectorMark-Start).
        var degrees = atan2(dx, -dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        hoverLocation = location
        hoveredIndex = Self.sliceIndex(atAngleDegrees: degrees, fractions: fractions)
    }

    /// Reine Geometrie-Auflösung: Winkel (0° = 12 Uhr, im Uhrzeigersinn) →
    /// Segment-Index anhand der kumulierten Anteile. `nonisolated`:
    /// Mapping-Logik ohne UI-Bezug, von überall aufrufbar.
    nonisolated static func sliceIndex(atAngleDegrees degrees: Double, fractions: [Double]) -> Int? {
        guard !fractions.isEmpty else { return nil }
        let total = fractions.reduce(0, +)
        guard total > 0 else { return nil }
        let target = degrees / 360 * total
        var cumulative: Double = 0
        for (index, fraction) in fractions.enumerated() {
            cumulative += fraction
            if target < cumulative || index == fractions.count - 1 {
                return index
            }
        }
        return nil
    }

    private func opacity(at index: Int) -> Double {
        guard let hoveredIndex else { return 1 }
        return index == hoveredIndex ? 1 : 0.35
    }

    private func tooltip(for slice: CategoryPieSlice) -> some View {
        ChartHoverTooltip(
            title: slice.name,
            rows: [
                ChartHoverTooltip.Row(
                    label: String(localized: "Betrag"),
                    value: amountText(slice.amount),
                    color: slice.color
                ),
                ChartHoverTooltip.Row(
                    label: String(localized: "Anteil"),
                    value: percentText(slice.amount),
                    color: nil
                )
            ]
        )
    }

    // MARK: - Presentation

    private func amountText(_ amount: Decimal) -> String {
        PrivacyAwareMoney.decimalString(amount, currency: currency, privacy: privacyState)
    }

    private func percentText(_ amount: Decimal) -> String {
        let total = totalAmount
        guard total > 0 else { return "0 %" }
        let percent = (amount / total) * Decimal(100)
        let rounded = NSDecimalNumber(decimal: percent).rounding(accordingToBehavior:
            NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
        ).intValue
        return "\(rounded) %"
    }

    private var accessibilitySummary: String {
        let values = slices.map { "\($0.name): \(amountText($0.amount))" }
        return String(localized: "Ausgaben nach Kategorie.") + " " + values.joined(separator: ", ")
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), upper)
    }
}
