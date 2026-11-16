import SwiftUI

/// Lädt einen Bereich bei Datenänderungen nur neu, solange er sichtbar ist.
///
/// Besuchte Bereiche bleiben im Fenster eingehängt. Mit `.task(id:)` lud
/// jeder von ihnen bei JEDER Änderung (Import, Bankabruf, Kategorie) im
/// Hintergrund neu. Jetzt merkt sich ein unsichtbarer Bereich nur, dass er
/// veraltet ist, und lädt beim nächsten Anzeigen einmal.
private struct ReloadWhenVisible: ViewModifier {
    @Environment(\.isWorkspaceActive) private var isActive
    let revision: Int
    let action: @MainActor () async -> Void
    @State private var loadedRevision: Int?

    func body(content: Content) -> some View {
        content.task(id: isActive ? revision : nil) {
            guard isActive, loadedRevision != revision else { return }
            await action()
            // Ein abgebrochenes Laden (neue Revision) zählt nicht als geladen.
            if !Task.isCancelled { loadedRevision = revision }
        }
    }
}

extension View {
    func reloadWhenVisible(revision: Int, perform action: @escaping @MainActor () async -> Void) -> some View {
        modifier(ReloadWhenVisible(revision: revision, action: action))
    }
}
