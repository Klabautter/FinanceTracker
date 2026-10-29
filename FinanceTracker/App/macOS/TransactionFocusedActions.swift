import SwiftUI

/// WP22: FocusedValues für die Transaktions-Ansicht, als eigener
/// ViewModifier, damit die View-Expression typ-checkbar bleibt.
struct TransactionFocusedActions: ViewModifier {
    @Environment(\.isWorkspaceActive) private var isActive
    @FocusState.Binding var isSearchFocused: Bool
    let quickActions: TransactionQuickActions?
    let undoActions: TransactionUndoActions?
    let model: TransactionsModel

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.focusSearch, isActive ? FocusSearchAction {
                isSearchFocused = true
            } : nil)
            .focusedSceneValue(\.refreshActiveScreen, isActive ? RefreshActiveScreenAction {
                Task { await model.refresh() }
            } : nil)
            .focusedSceneValue(\.transactionQuickActions, isActive ? quickActions : nil)
            .focusedSceneValue(\.transactionUndoActions, isActive ? undoActions : nil)
    }
}

/// Bearbeiten → Widerrufen nach „Nicht anzeigen“ in den wiederkehrenden
/// Vorschlägen. Nutzt dieselbe Menü-Anbindung wie die Transaktionen.
struct SuggestionUndoFocusedAction: ViewModifier {
    @Environment(\.isWorkspaceActive) private var isActive
    let model: FixkostenModel

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.transactionUndoActions, isActive ? undoActions : nil)
    }

    private var undoActions: TransactionUndoActions? {
        guard model.lastDismissedSuggestion != nil else { return nil }
        return TransactionUndoActions(
            undo: { Task { await model.undoLastDismiss() } },
            redo: {},
            canUndo: true,
            canRedo: false,
            undoName: String(localized: "Vorschlag ausblenden"),
            redoName: nil
        )
    }
}
