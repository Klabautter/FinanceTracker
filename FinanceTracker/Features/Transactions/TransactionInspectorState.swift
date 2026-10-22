import Foundation

/// P0 (#31): Inspector-Sichtbarkeit für Tabellen-Screens (macOS).
///
/// Regel: Eine (neue) Auswahl öffnet den Inspector NICHT automatisch und das
/// Leeren der Auswahl schließt ihn NICHT zwangsläufig, der Inspector öffnet
/// erst bei expliziter Aktion (Doppelklick, Info-Button/Toolbar, ⌘I,
/// Deep-Link-Ziel). Reine View-State-Logik ohne SwiftUI-Import, damit sie
/// per Unit-Test prüfbar bleibt (keine UI-Durchklick-Tests).
struct TransactionInspectorState: Equatable, Sendable {
    private(set) var isPresented = false

    mutating func openExplicitly() {
        isPresented = true
    }

    mutating func close() {
        isPresented = false
    }

    mutating func toggle() {
        isPresented.toggle()
    }

    /// Auswahlwechsel (inkl. Leeren) ändert die Sichtbarkeit nie.
    mutating func selectionDidChange() {
    }
}
