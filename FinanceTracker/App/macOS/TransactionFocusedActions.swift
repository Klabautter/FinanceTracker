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
