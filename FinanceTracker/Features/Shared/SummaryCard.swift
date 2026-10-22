import SwiftUI

struct SummaryCard: View {
    let title: String
    let amount: Decimal
    let currency: CurrencyCode
    let tint: Color
    var trendPercent: Double? = nil

    @Environment(PrivacyPresentationState.self) private var privacyState

    var body: some View {
        MetricCard(
            title: title,
            value: PrivacyAwareMoney.decimalString(amount, currency: currency, privacy: privacyState),
            tint: tint,
            prominence: .secondary,
            trendPercent: trendPercent
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(PrivacyAwareMoney.accessibilityLabel(amount, currency: currency, privacy: privacyState))")
    }
}
