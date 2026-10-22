import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("PrivacyPresentation")
struct PrivacyPresentationTests {

    private func makeState(
        defaults: UserDefaults,
        forcedHidesAmounts: Bool? = nil
    ) -> PrivacyPresentationState {
        PrivacyPresentationState(
            defaults: defaults,
            forcedHidesAmounts: forcedHidesAmounts
        )
    }

    private func makeDefaults() -> UserDefaults {
        let name = "privacy-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private let eur = Money(amount: Decimal(string: "1234.56")!, currency: .eur)

    @Test("Privacy OFF zeigt den formatierten Betrag")
    func offShowsAmount() {
        let state = makeState(defaults: makeFreshDefaults())
        let shown = PrivacyAwareMoney.string(eur, privacy: state)
        #expect(state.hidesAmounts == false)
        #expect(!shown.contains("•••"))
        #expect(shown.contains("1.234,56") || shown.contains("1,234.56"))
    }

    private func makeFreshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "privacy-tests-\(UUID().uuidString)")!
    }

    @Test("Privacy ON maskiert den visuellen Betrag")
    func onMasksAmount() {
        let state = makeState(defaults: makeFreshDefaults())
        state.hidesAmounts = true
        #expect(PrivacyAwareMoney.string(eur, privacy: state) == "•••")
    }

    @Test("Privacy ON: Accessibility-String enthält keinen Betrag")
    func onAccessibilityHasNoAmount() {
        let state = makeState(defaults: makeFreshDefaults())
        state.hidesAmounts = true
        let label = PrivacyAwareMoney.accessibilityLabel(eur, privacy: state, signed: true)
        #expect(label == "Betrag verborgen")
        #expect(!label.contains("1.234"))
        #expect(!label.contains("1,234"))
    }

    @Test("Privacy OFF: Accessibility-String zeigt signierten Betrag")
    func offAccessibilitySigned() {
        let state = makeState(defaults: makeFreshDefaults())
        let label = PrivacyAwareMoney.accessibilityLabel(eur, privacy: state, signed: true)
        #expect(label == MoneyFormatter.signed(eur))
    }

    @Test("Signed Privacy: positive und negative Beträge maskiert")
    func signedPrivacy() {
        let state = makeState(defaults: makeFreshDefaults())
        state.hidesAmounts = true
        let negative = Money(amount: Decimal(string: "-42.50")!, currency: .eur)
        #expect(PrivacyAwareMoney.signed(eur, privacy: state) == "•••")
        #expect(PrivacyAwareMoney.signed(negative, privacy: state) == "•••")
    }

    @Test("Zero und große Beträge maskiert")
    func zeroAndLarge() {
        let state = makeState(defaults: makeFreshDefaults())
        state.hidesAmounts = true
        let zero = Money(amount: 0, currency: .eur)
        let large = Money(amount: Decimal(string: "1234567890.12")!, currency: .eur)
        #expect(PrivacyAwareMoney.decimalString(zero.amount, currency: .eur, privacy: state) == "•••")
        #expect(PrivacyAwareMoney.decimalString(large.amount, currency: .eur, privacy: state) == "•••")
        #expect(PrivacyAwareMoney.accessibilityLabel(large.amount, currency: .eur, privacy: state) == "Betrag verborgen")
    }

    @Test("Einstellung persistiert über injizierte UserDefaults-Suite")
    func persistsThroughInjectedDefaults() {
        let defaults = makeFreshDefaults()
        let first = makeState(defaults: defaults)
        #expect(first.hidesAmounts == false)
        first.hidesAmounts = true

        let second = makeState(defaults: defaults)
        #expect(second.hidesAmounts == true)
    }

    @Test("UI-Test-Flag erzwingt verdeckte Beträge gegen persistierten OFF-State")
    func launchArgumentForcesHidden() {
        let defaults = makeFreshDefaults()
        defaults.set(false, forKey: PrivacyPresentationState.defaultsKey)
        let state = makeState(defaults: defaults, forcedHidesAmounts: true)
        #expect(state.hidesAmounts == true)
        #expect(PrivacyAwareMoney.string(eur, privacy: state) == "•••")
    }

    /// WP1 (§11-12): `-ui-testing-privacy-off` überschreibt einen
    /// persistierten ON-State: Visual QA darf nicht kontaminiert werden.
    @Test("Privacy-OFF-Override gewinnt gegen persistierten ON-State")
    func privacyOffOverrideBeatsPersistedOn() {
        let defaults = makeFreshDefaults()
        defaults.set(true, forKey: PrivacyPresentationState.defaultsKey)
        let state = makeState(defaults: defaults, forcedHidesAmounts: false)
        #expect(state.hidesAmounts == false)
        #expect(!PrivacyAwareMoney.string(eur, privacy: state).contains("•••"))
    }

    /// WP1 (§12): Ohne Override-Flag gilt der persistierte User-Wert.
    @Test("Ohne Override gilt der persistierte Wert")
    func noOverrideUsesPersistedValue() {
        let defaults = makeFreshDefaults()
        defaults.set(true, forKey: PrivacyPresentationState.defaultsKey)
        let state = makeState(defaults: defaults)
        #expect(state.hidesAmounts == true)
    }

    /// WP1 (§12): OFF-Override persistiert nicht als User-Einstellung
    /// UI-Tests verändern den normalen User-State nicht (§17).
    @Test("OFF-Override schreibt nicht in persistierten User-State")
    func offOverrideDoesNotPersist() {
        let defaults = makeFreshDefaults()
        defaults.set(true, forKey: PrivacyPresentationState.defaultsKey)
        let state = makeState(defaults: defaults, forcedHidesAmounts: false)
        #expect(state.hidesAmounts == false)
        #expect(defaults.bool(forKey: PrivacyPresentationState.defaultsKey) == true)
    }

    @Test("Chart-Summaries geben bei Privacy ON keine Beträge weiter")
    func chartSummariesHideAmounts() {
        let hidden = ChartAccessibility.monthlyCashflowSummary(
            points: [MonthlyCashflowPoint(monthStart: Date(), income: 100, spending: 40)],
            currency: .eur,
            amountsHidden: true
        )
        #expect(!hidden.contains("100"))
        #expect(!hidden.contains("40"))
        #expect(hidden.contains("verborgen"))
    }
}