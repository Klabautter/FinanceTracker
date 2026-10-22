import Foundation
import SwiftUI

/// Globaler Privacy-Zustand für Betragsdarstellung.
///
/// App-Presentation-Dependency (kein Singleton): Instanz wird im App-Root
/// erzeugt, als `@Observable` über die SwiftUI-Umgebung verteilt und an
/// Models explizit injiziert. Persistiert den Zustand unter dem historischen
/// Key, damit bestehende Installationen ihre Einstellung behalten.
@MainActor
@Observable
final class PrivacyPresentationState {
    static let defaultsKey = "privacyModeEnabled"

    var hidesAmounts: Bool {
        didSet {
            defaults.set(hidesAmounts, forKey: Self.defaultsKey)
        }
    }

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        forcedHidesAmounts: Bool? = nil
    ) {
        self.defaults = defaults
        // WP1 (§12): Expliziter Launch-Override gewinnt (`true` = ON erzwingen,
        // `false` = OFF erzwingen), sonst gilt die persistierte Einstellung,
        // damit entstehen deterministische UI-Test-States.
        switch forcedHidesAmounts {
        case .some(let forced):
            hidesAmounts = forced
        case nil:
            hidesAmounts = defaults.bool(forKey: Self.defaultsKey)
        }
    }

    /// Maskiert einen formatierten Betrag, wenn Privacy aktiv ist.
    func masked(_ formatted: String) -> String {
        hidesAmounts ? "•••" : formatted
    }
}

/// Zentrale Privacy-aware Money-Presentation.
///
/// Kein Feature entscheidet selbst, wie Privacy auf einen Betrag angewendet
/// wird: visuelle Strings, signed Variante und Accessibility-Strings laufen
/// ausschließlich über diese Schicht.
@MainActor
enum PrivacyAwareMoney {
    static func string(
        _ money: Money,
        privacy: PrivacyPresentationState,
        locale: Locale = .current
    ) -> String {
        privacy.masked(MoneyFormatter.string(money, locale: locale))
    }

    static func signed(
        _ money: Money,
        privacy: PrivacyPresentationState,
        locale: Locale = .current
    ) -> String {
        privacy.masked(MoneyFormatter.signed(money, locale: locale))
    }

    static func decimalString(
        _ value: Decimal,
        currency: CurrencyCode,
        privacy: PrivacyPresentationState,
        locale: Locale = .current
    ) -> String {
        privacy.masked(MoneyFormatter.decimalString(value, currency: currency, locale: locale))
    }

    /// Summe mit explizitem Vorzeichen: `+` für Einnahmen/positive Salden,
    /// `−` für Ausgaben/negative Salden. `kind` legt die Bedeutung fest,
    /// wenn der Wert selbst (z. B. eine Ausgabensumme) positiv geführt wird.
    enum SignedKind { case income, expense, balance }

    static func signedTotal(
        _ value: Decimal,
        kind: SignedKind,
        currency: CurrencyCode,
        privacy: PrivacyPresentationState,
        locale: Locale = .current
    ) -> String {
        let magnitude = value < 0 ? -value : value
        let base = decimalString(magnitude, currency: currency, privacy: privacy, locale: locale)
        guard !privacy.hidesAmounts, magnitude != 0 else { return base }
        switch kind {
        case .income: return "+" + base
        case .expense: return "−" + base
        case .balance: return (value < 0 ? "−" : "+") + base
        }
    }

    /// Accessibility-Darstellung eines Betrags. Bei Privacy ON darf der
    /// echte Betrag niemals im Label stehen.
    static func accessibilityLabel(
        _ money: Money,
        privacy: PrivacyPresentationState,
        signed: Bool = false
    ) -> String {
        guard !privacy.hidesAmounts else { return String(localized: "Betrag verborgen") }
        return signed ? MoneyFormatter.signed(money) : MoneyFormatter.string(money)
    }

    /// Accessibility-Darstellung für einen Dezimalwert mit Währung.
    static func accessibilityLabel(
        _ value: Decimal,
        currency: CurrencyCode,
        privacy: PrivacyPresentationState
    ) -> String {
        guard !privacy.hidesAmounts else { return String(localized: "Betrag verborgen") }
        return MoneyFormatter.decimalString(value, currency: currency)
    }

    /// Hinweis für Export-Flows: Privacy Mode ist UI-Presentation und darf
    /// Exportdaten nie verändern (Export = echte Daten).
    static var exportContainsRealAmountsHint: String {
        String(localized: "Der Export enthält echte Beträge, unabhängig von „Beträge verbergen“.")
    }
}
