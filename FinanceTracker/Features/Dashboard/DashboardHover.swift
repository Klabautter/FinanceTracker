import SwiftUI

/// Zeilen-Hover für Listendarstellungen.
///
/// Auf dem Mac erwartet man Rückmeldung, bevor man klickt: Wenn eine Zeile
/// anklickbar ist, muss sie beim Überfahren erkennbar sein. Der Effekt liegt
/// zentral, damit alle Darstellungen sich gleich verhalten.
struct HoverHighlight: ViewModifier {
    var tint: Color
    var cornerRadius: CGFloat = 5
    /// Nicht anklickbare Zeilen bekommen keinen Hover, sonst verspricht
    /// die Oberfläche eine Aktion, die es nicht gibt.
    var isEnabled: Bool = true

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, AppSpacing.s)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering && isEnabled ? tint : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                guard isEnabled else { return }
                isHovering = hovering
            }
    }
}

extension View {
    func hoverHighlight(
        tint: Color,
        cornerRadius: CGFloat = 5,
        isEnabled: Bool = true
    ) -> some View {
        modifier(HoverHighlight(tint: tint, cornerRadius: cornerRadius, isEnabled: isEnabled))
    }
}

/// Ein Monat des Verlaufs-Charts unter dem Zeiger.
///
/// Die Trefferzone wird aus der Zeigerposition und der Spaltenbreite
/// berechnet. Das funktioniert unabhängig davon, wie der Chart gezeichnet
/// ist, und braucht kein Swift-Charts-Overlay.
struct HoveredMonth: Equatable {
    let point: MonthlyCashflowPoint
    let index: Int
    /// Mittelpunkt der Spalte in Chart-Koordinaten (für die Tooltip-Position).
    let centerX: CGFloat
}

enum ChartHoverMath {
    /// Index der Spalte unter `x` bei gleich breiten Spalten.
    static func columnIndex(x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0, width > 0, x >= 0, x <= width else { return nil }
        let columnWidth = width / CGFloat(count)
        let index = Int(x / columnWidth)
        return min(max(index, 0), count - 1)
    }

    /// Mittelpunkt der Spalte `index`.
    static func columnCenter(index: Int, width: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let columnWidth = width / CGFloat(count)
        return columnWidth * (CGFloat(index) + 0.5)
    }

    /// Hält den Tooltip innerhalb der Chartbreite.
    static func clampedTooltipX(center: CGFloat, tooltipWidth: CGFloat, chartWidth: CGFloat) -> CGFloat {
        let half = tooltipWidth / 2
        guard chartWidth > tooltipWidth else { return chartWidth / 2 }
        return min(max(center, half), chartWidth - half)
    }
}
