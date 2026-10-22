import Testing

@testable import FinanceTracker

@Suite("Gemountete Bereiche")
struct AppSectionNavigationStateTests {
    @Test("Nur der aktuelle und der zuletzt geöffnete Bereich bleiben geladen")
    func keepsOnlyTwoRecentSections() {
        var state = AppSectionNavigationState()
        state.select(.transactions)
        state.select(.analytics)
        state.select(.accounts)

        #expect(state.selection == .accounts)
        #expect(Set(state.mountedSections) == [.analytics, .accounts])
    }

    @Test("Zurück zum vorherigen Bereich behält beide geladen")
    func switchingBackKeepsPair() {
        var state = AppSectionNavigationState()
        state.select(.transactions)
        state.select(.overview)
        state.select(.transactions)

        #expect(Set(state.mountedSections) == [.overview, .transactions])
    }
}
