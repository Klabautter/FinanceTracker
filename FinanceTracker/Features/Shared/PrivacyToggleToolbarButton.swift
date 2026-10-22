import SwiftUI

/// MacUX-Audit: Privacy-Toggle direkt in der Toolbar (Auge-Icon, wie in
/// Bank-Apps üblich) statt nur in den Settings: Beträge lassen sich aus
/// jedem Screen heraus verbergen/anzeigen. Der Toggle beschreibt denselben
/// `PrivacyPresentationState` wie der Settings-Eintrag; Updates laufen über
/// Observation an alle Konsumenten.
struct PrivacyToggleToolbarButton: View {
    @Environment(PrivacyPresentationState.self) private var privacyState

    var body: some View {
        Button {
            privacyState.hidesAmounts.toggle()
        } label: {
            Label(
                privacyState.hidesAmounts ? String(localized: "Beträge anzeigen") : String(localized: "Beträge verbergen"),
                systemImage: privacyState.hidesAmounts ? "eye.slash" : "eye"
            )
        }
        .accessibilityLabel("Beträge in der gesamten App verbergen oder anzeigen")
        .help(privacyState.hidesAmounts ? Text("Beträge anzeigen") : Text("Beträge verbergen"))
    }
}
