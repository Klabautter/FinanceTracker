import Foundation

/// Anzeige der Cashback-Summe: je Währung getrennt, nie verrechnet.
@MainActor
enum CashbackPresentation {
    nonisolated static var caption: String { String(localized: "nicht mit Ausgaben verrechnet") }

    /// z. B. „+12,47 € · +1,14 $"; `nil`, wenn es keinen Cashback gibt.
    static func text(_ totals: [CashbackTotal], privacy: PrivacyPresentationState) -> String? {
        guard !totals.isEmpty else { return nil }
        return totals
            .map { "+" + PrivacyAwareMoney.string(Money(amount: $0.amount, currency: $0.currency), privacy: privacy) }
            .joined(separator: " · ")
    }

    static func accessibilityText(_ totals: [CashbackTotal], privacy: PrivacyPresentationState) -> String? {
        guard !totals.isEmpty else { return nil }
        return totals
            .map { PrivacyAwareMoney.accessibilityLabel(Money(amount: $0.amount, currency: $0.currency), privacy: privacy) }
            .joined(separator: ", ")
    }

    /// Die Cashback-Kennzahl steht immer da (auch mit 0), damit die
    /// Kennzahlenzeile beim Wechsel zwischen Monaten nicht umbricht.
    static func metric(
        _ totals: [CashbackTotal],
        baseCurrency: CurrencyCode,
        privacy: PrivacyPresentationState
    ) -> MetricStripItem {
        let zero = Money(amount: 0, currency: baseCurrency)
        return MetricStripItem(
            label: String(localized: "Cashback"),
            value: text(totals, privacy: privacy) ?? PrivacyAwareMoney.string(zero, privacy: privacy),
            caption: caption,
            tone: totals.isEmpty ? .neutral : .positive,
            accessibilityValue: accessibilityText(totals, privacy: privacy)
                ?? PrivacyAwareMoney.accessibilityLabel(zero, privacy: privacy)
        )
    }
}
