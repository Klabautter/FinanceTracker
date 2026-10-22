import SwiftUI

struct PocketEditorSheet: View {
    let model: PocketsModel
    let editing: TransactionCollection?

    @State private var input: PocketEditorInput
    @State private var localError: String?
    @Environment(\.dismiss) private var dismiss

    init(model: PocketsModel, editing: TransactionCollection?) {
        self.model = model
        self.editing = editing
        _input = State(initialValue: editing.map { PocketEditorInput(collection: $0) } ?? PocketEditorInput())
    }

    private var activeAccountIDs: Set<UUID> {
        Set(model.activeAccounts.map(\.id))
    }

    private var validationError: PocketEditorValidationError? {
        input.validationError(activeAccountIDs: activeAccountIDs)
    }

    var body: some View {
        AdaptiveSheet(title: editing == nil ? String(localized: "Neue Sammlung") : String(localized: "Sammlung bearbeiten")) {
            Form {
                Section("Sammlung") {
                    TextField("Name", text: $input.name, prompt: Text("z. B. Urlaub in Italien"))
                        .accessibilityIdentifier("pocket-name-field")
                    // Der Picker zeigt das gewählte Symbol selbst.
                    FinanceIconPicker(selection: $input.systemIconName)
                }

                Section("Zeitraum") {
                    DatePicker("Von", selection: $input.startDateInclusive, displayedComponents: .date)
                    DatePicker("Bis (einschließlich)", selection: $input.endDateInclusive, displayedComponents: .date)
                    Text("Der gesamte Bis-Tag gehört zur Sammlung.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Konten und Karten") {
                    if model.activeAccounts.isEmpty {
                        Label("Es gibt kein aktives Konto und keine aktive Karte.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AppPalette.warning)
                    } else {
                        ForEach(model.activeAccounts) { account in
                            Toggle(isOn: Binding(
                                get: { input.selectedAccountIDs.contains(account.id) },
                                set: { selected in
                                    if selected {
                                        input.selectedAccountIDs.insert(account.id)
                                    } else {
                                        input.selectedAccountIDs.remove(account.id)
                                    }
                                }
                            )) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.name)
                                        Text(account.hasExternalIdentifier
                                             ? "\(account.type.displayName) · \(account.currency.rawValue) · \(account.presentationIdentifier)"
                                             : "\(account.type.displayName) · \(account.currency.rawValue)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: account.type.systemImage)
                                }
                            }
                        }
                    }
                }

                Section {
                    Label(
                        "Transaktionen werden automatisch nach Zeitraum und Konten zugeordnet.",
                        systemImage: "wand.and.stars"
                    )
                    Text("Sammlungen ändern weder globale Analysen noch Budgets und erzeugen keine Kopien von Transaktionen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message = localError ?? validationError?.message {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AppPalette.critical)
                    }
                }
            }
            .financeFormStyle()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .disabled(model.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        Task {
                            localError = nil
                            if await model.save(input: input, replacing: editing) {
                                dismiss()
                            } else {
                                localError = model.errorMessage
                            }
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(validationError != nil || model.isSaving)
                    .accessibilityIdentifier("pocket-save-button")
                }
            }
        }
        #if os(macOS)
        .frame(width: 500, height: 580)
        #endif
        .interactiveDismissDisabled(model.isSaving)
    }
}
