import SwiftUI

/// Privacy-aware Betragsanzeige (Roadmap #188 / WP1).
///
/// Der Privacy-Zustand kommt aus der Umgebung (App-Root), nicht aus einem
/// Singleton. Accessibility-Label läuft über `PrivacyAwareMoney`, damit
/// VoiceOver den echten Betrag niemals vorliest, während Beträge verborgen
/// sind.
struct MoneyText: View {
    let money: Money
    var signed: Bool = false
    /// Negative Beträge rot statt neutral einfärben (Salden, Netto-Bewegungen).
    var tintsNegative: Bool = false

    @Environment(PrivacyPresentationState.self) private var privacyState

    var body: some View {
        Text(formatted)
            .monospacedDigit()
            .foregroundStyle(color)
            .accessibilityLabel(accessibilityText)
    }

    private var formatted: String {
        signed ? PrivacyAwareMoney.signed(money, privacy: privacyState)
               : PrivacyAwareMoney.string(money, privacy: privacyState)
    }

    private var accessibilityText: String {
        PrivacyAwareMoney.accessibilityLabel(money, privacy: privacyState, signed: signed)
    }

    private var color: Color {
        guard signed, !privacyState.hidesAmounts else { return .primary }
        if money.isPositive { return AppPalette.positive }
        if tintsNegative, money.amount < 0 { return AppPalette.critical }
        return Color.primary
    }
}
