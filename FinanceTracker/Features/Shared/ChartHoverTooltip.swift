import SwiftUI

/// Wiederverwendbarer Hover-Tooltip für Charts (macOS + iOS): material-
/// Hintergrund, Titelzeile plus Label/Wert-Zeilen mit optionalem Farb-Dot.
/// Die Positionierung übernimmt der aufrufende Chart-Overlay-Code.
struct ChartHoverTooltip: View {
    struct Row: Identifiable, Equatable {
        let label: String
        let value: String
        var color: Color?

        var id: String { label }
    }

    let title: String
    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ForEach(rows) { row in
                HStack(spacing: AppSpacing.s) {
                    if let color = row.color {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                    Text(row.label)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: AppSpacing.s)
                    Text(row.value)
                        .font(.caption.monospacedDigit().weight(.medium))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 170)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppPalette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }
}
