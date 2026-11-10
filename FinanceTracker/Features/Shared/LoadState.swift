import Foundation

/// Ladezustand einer Ansicht als EIN Wert statt der Kombination aus
/// `isLoading`, `errorMessage` und „Liste leer“, aus der jede View ihre
/// eigene Regel baute (AGENTS #37).
///
/// Konvention: Ein Model hält `loadState` für das Laden seiner Daten und
/// getrennt davon `actionError` für Speichern/Löschen/Eingabefehler. Ein
/// Eingabefehler darf nie als „konnte nicht geladen werden“ erscheinen,
/// und ein Laden endet immer (`defer`), auch wenn es abgebrochen wird.
enum LoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool { self == .loading }

    /// Meldung des letzten fehlgeschlagenen Ladens.
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Was der Screen zeigt, aus Ladezustand und Inhalt. Eine Regel für alle
/// Screens: Vorhandener Inhalt gewinnt immer (nie ein Spinner oder eine
/// Fehlerseite über Daten; Fehler und Nachladen erscheinen dann als
/// Hinweis), sonst Fehler vor Laden vor leer.
enum ScreenState: Equatable, Sendable {
    case loading
    case failed(String)
    case empty
    case content

    init(load: LoadState, hasContent: Bool) {
        if hasContent {
            self = .content
            return
        }
        switch load {
        case .failed(let message): self = .failed(message)
        case .loading, .idle: self = .loading
        case .loaded: self = .empty
        }
    }
}
