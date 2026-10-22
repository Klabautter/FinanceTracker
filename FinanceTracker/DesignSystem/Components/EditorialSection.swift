import SwiftUI

/// Editorialer Sektionskopf (Roadmap #78/#175): Typografie statt Card-
/// Hintergrund. Optionaler Inline-Action rechts.
struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(AppTypography.sectionTitle)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(AppTypography.supporting)
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// Kompakte Kennzahl (Roadmap #79): Label über Wert, ohne Card.
struct LabeledMetric: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .eyebrowStyle()
            Text(value)
                .font(AppTypography.metric)
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let caption {
                Text(caption)
                    .font(AppTypography.compactMetadata)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PlanningSummaryMetric: Identifiable {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var id: String { label }
}

/// Gemeinsame Hierarchie der Planungs-Screens: eine dominante Kennzahl mit
/// optionalem Fortschritt, sekundäre Fakten rechts, optionaler Hinweis,
/// alles in einer Karte.
struct PlanningSummaryHero: View {
    let title: String
    let value: String
    let caption: String
    let systemImage: String
    var valueColor: Color = .primary
    var progress: Double?
    let metrics: [PlanningSummaryMetric]
    var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.l) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: AppSpacing.xl) {
                    primaryMetric
                        .frame(maxWidth: .infinity, alignment: .leading)
                    horizontalMetrics
                        .fixedSize()
                }
                .frame(minWidth: 660)

                VStack(alignment: .leading, spacing: AppSpacing.l) {
                    primaryMetric
                    compactMetrics
                }
            }

            if let notice {
                InlineNotice(message: notice, tone: .warning)
            }
        }
        .financeCard(padding: 22)
        .accessibilityElement(children: .contain)
    }

    private var progressTone: AppTone {
        guard let progress else { return .neutral }
        if progress > 1 { return .critical }
        if progress >= 0.85 { return .warning }
        return .positive
    }

    private var primaryMetric: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text(title).eyebrowStyle()

            Text(value)
                .font(AppTypography.heroMetric)
                .tracking(-0.8)
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.64)

            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let progress {
                HStack(spacing: AppSpacing.m) {
                    FinanceProgressBar(fraction: progress, tone: progressTone, height: 8)
                        .frame(maxWidth: 420)
                    Text("\(Int((progress * 100).rounded())) %")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(progressTone.foregroundColor)
                }
                .padding(.top, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((progress * 100).rounded())) Prozent")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var horizontalMetrics: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Rectangle().fill(AppPalette.hairline).frame(width: 1, height: 52)
                }
                metricView(metric)
                    .padding(.horizontal, AppSpacing.l)
            }
        }
    }

    private var compactMetrics: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
            alignment: .leading,
            spacing: AppSpacing.m
        ) {
            ForEach(metrics) { metric in
                metricView(metric)
            }
        }
    }

    private func metricView(_ metric: PlanningSummaryMetric) -> some View {
        LabeledMetric(
            label: metric.label,
            value: metric.value,
            valueColor: metric.valueColor
        )
    }
}
