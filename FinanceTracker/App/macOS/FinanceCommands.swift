import SwiftUI

// MARK: - Focused Actions (WP22)

/// Öffnet die Command Palette (⌘K), gesetzt vom aktiven Root-Screen.
struct OpenCommandPaletteAction {
    let open: () -> Void
}

private struct OpenCommandPaletteKey: FocusedValueKey {
    typealias Value = OpenCommandPaletteAction
}

extension FocusedValues {
    var openCommandPalette: OpenCommandPaletteAction? {
        get { self[OpenCommandPaletteKey.self] }
        set { self[OpenCommandPaletteKey.self] = newValue }
    }
}

/// Öffnet die Prüfliste aus dem fokussierten Fenster.
struct OpenReviewQueueAction {
    let open: () -> Void
}

private struct OpenReviewQueueKey: FocusedValueKey {
    typealias Value = OpenReviewQueueAction
}

extension FocusedValues {
    var openReviewQueue: OpenReviewQueueAction? {
        get { self[OpenReviewQueueKey.self] }
        set { self[OpenReviewQueueKey.self] = newValue }
    }
}

/// Aktualisiert den fokussierten Screen (⌘R).
struct RefreshActiveScreenAction {
    let refresh: () -> Void
}

private struct RefreshActiveScreenKey: FocusedValueKey {
    typealias Value = RefreshActiveScreenAction
}

extension FocusedValues {
    var refreshActiveScreen: RefreshActiveScreenAction? {
        get { self[RefreshActiveScreenKey.self] }
        set { self[RefreshActiveScreenKey.self] = newValue }
    }
}

/// Fokussiert die Suche im fokussierten Screen (⌘F).
struct FocusSearchAction {
    let focus: () -> Void
}

private struct FocusSearchKey: FocusedValueKey {
    typealias Value = FocusSearchAction
}

extension FocusedValues {
    var focusSearch: FocusSearchAction? {
        get { self[FocusSearchKey.self] }
        set { self[FocusSearchKey.self] = newValue }
    }
}

/// Transaktions-Aktionen (nur aktiv bei aktiver Auswahl und ohne
/// Texteingabe-Fokus, §161).
struct TransactionQuickActions {
    let toggleReviewed: () -> Void
    let selectAll: () -> Void
    let clearSelection: () -> Void
}

private struct TransactionQuickActionsKey: FocusedValueKey {
    typealias Value = TransactionQuickActions
}

extension FocusedValues {
    var transactionQuickActions: TransactionQuickActions? {
        get { self[TransactionQuickActionsKey.self] }
        set { self[TransactionQuickActionsKey.self] = newValue }
    }
}

/// Transaktions-Undo (Roadmap #26, P1): eigener deterministischer Stack im
/// `TransactionsModel` (await-bar, unit-testbar). Die View liefert die
/// Aktionen als FocusedValue; das Menü ruft nur auf (keine Logik hier).
/// Bewusst `replacing: .undoRedo` (vorher ausgeschlossen, jetzt aktiviert):
/// ⌘Z/⇧⌘Z wirken auf Transaktions-Edits, solange kein Texteingabe-Fokus
/// besteht (die View liefert dann `nil`, Buttons sind disabled).
struct TransactionUndoActions {
    let undo: () -> Void
    let redo: () -> Void
    let canUndo: Bool
    let canRedo: Bool
    let undoName: String?
    let redoName: String?
}

private struct TransactionUndoActionsKey: FocusedValueKey {
    typealias Value = TransactionUndoActions
}

extension FocusedValues {
    var transactionUndoActions: TransactionUndoActions? {
        get { self[TransactionUndoActionsKey.self] }
        set { self[TransactionUndoActionsKey.self] = newValue }
    }
}

/// Wechselt den Sidebar-Bereich (⌘1…⌘9), gesetzt vom macOS-Root.
struct SelectSectionAction {
    let select: (AppSection) -> Void
}

private struct SelectSectionKey: FocusedValueKey {
    typealias Value = SelectSectionAction
}

extension FocusedValues {
    var selectSection: SelectSectionAction? {
        get { self[SelectSectionKey.self] }
        set { self[SelectSectionKey.self] = newValue }
    }
}

// MARK: - Commands

/// WP22: Apple-native Menüleisten-Commands statt unsichtbarer
/// 0×0-Shortcut-Buttons. Transaktionsaktionen verwenden bewusst keine
/// Text-Shortcuts (außer Undo/Redo, P1) und sind nur im fokussierten
/// Screen aktiv.
struct FinanceCommands: Commands {
    @FocusedValue(\.openCommandPalette) private var openCommandPalette: OpenCommandPaletteAction?
    @FocusedValue(\.openReviewQueue) private var openReviewQueue: OpenReviewQueueAction?
    @FocusedValue(\.refreshActiveScreen) private var refreshActiveScreen: RefreshActiveScreenAction?
    @FocusedValue(\.focusSearch) private var focusSearch: FocusSearchAction?
    @FocusedValue(\.transactionQuickActions) private var quickActions: TransactionQuickActions?
    @FocusedValue(\.transactionUndoActions) private var undoActions: TransactionUndoActions?
    @FocusedValue(\.selectSection) private var selectSection: SelectSectionAction?
    @Bindable var updateChecker: UpdateChecker

    var body: some Commands {
        // App-Menü: Updates über Sparkle.
        CommandGroup(after: .appInfo) {
            Button("Nach Updates suchen …") {
                updateChecker.checkForUpdates()
            }
            .disabled(!updateChecker.canCheck)
            Toggle("Automatisch nach Updates suchen", isOn: $updateChecker.checksAutomatically)
                .disabled(!updateChecker.isActive)
        }

        // ⌘1…⌘9 in Sidebar-Reihenfolge (macOS-Konvention bei fester Seitenleiste).
        CommandMenu("Gehe zu") {
            ForEach(Array(AppSection.shortcutSections.enumerated()), id: \.element) { index, section in
                Button(section.title) {
                    selectSection?.select(section)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .disabled(selectSection == nil)
            }
        }

        CommandGroup(after: .newItem) {
            Button("Befehlspalette öffnen") {
                openCommandPalette?.open()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(openCommandPalette == nil)

            Button("Prüfliste öffnen") {
                openReviewQueue?.open()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(openReviewQueue == nil)

            Button("Aktuellen Bereich aktualisieren") {
                refreshActiveScreen?.refresh()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(refreshActiveScreen == nil)

            Button("Suchen") {
                focusSearch?.focus()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(focusSearch == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Alle sichtbaren Transaktionen auswählen") {
                quickActions?.selectAll()
            }
            .disabled(quickActions == nil)

            Button("Transaktionsauswahl aufheben") {
                quickActions?.clearSelection()
            }
            .disabled(quickActions == nil)

            Button("Prüfstatus der Auswahl umschalten") {
                quickActions?.toggleReviewed()
            }
            .disabled(quickActions == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            Button(undoTitle) {
                undoActions?.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(undoActions?.canUndo ?? false))

            Button(redoTitle) {
                undoActions?.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!(undoActions?.canRedo ?? false))
        }
    }

    private var undoTitle: String {
        if let name = undoActions?.undoName {
            String(localized: "„\(name)“ rückgängig machen")
        } else {
            String(localized: "Rückgängig machen")
        }
    }

    private var redoTitle: String {
        if let name = undoActions?.redoName {
            String(localized: "„\(name)“ wiederholen")
        } else {
            String(localized: "Wiederholen")
        }
    }
}
