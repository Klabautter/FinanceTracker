import SwiftUI

/// Primary hero metric (dominant monthly spending) and compact
/// secondary metrics. Finance content stays calm: no glass, no color
/// noise beyond semantic tints.
struct MetricCard: View {
    enum Prominence {
        case primary
        case secondary

        var titleFont: Font {
            switch self {
            case .primary: AppTypography.metric
            case .secondary: AppTypography.label
            }
        }

        var valueFont: Font {
            switch self {
            case .primary: AppTypography.heroMetric
            case .secondary: AppTypography.compactMetric
            }
        }
    }

    let title: String
    let value: String
    var tint: Color = .primary
    var prominence: Prominence = .secondary
    var trendPercent: Double?
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text(title)
                .font(prominence.titleFont)
                .foregroundStyle(.secondary)

            Text(value)
                .font(prominence.valueFont)
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let trendPercent, abs(trendPercent) >= 0.05 {
                let worsened = trendPercent > 0
                let percentText = String(format: "%.1f", abs(trendPercent))
                Label {
                    Text(String(format: "%.1f %%", abs(trendPercent)))
                } icon: {
                    Image(systemName: worsened ? "arrow.up.right" : "arrow.down.right")
                }
                .font(AppTypography.metadata.weight(.medium))
                .foregroundStyle(worsened ? Color.red : Color.green)
                .accessibilityLabel(worsened ? Text("gestiegen um \(percentText) Prozent") : Text("gesunken um \(percentText) Prozent"))
            }

            if let caption {
                Text(caption)
                    .font(AppTypography.compactMetadata)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.l)
        .appSurface(.groupedContent)
        .accessibilityElement(children: .combine)
    }
}
