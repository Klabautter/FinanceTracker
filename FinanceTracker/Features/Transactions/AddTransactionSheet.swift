import SwiftUI

/// Manual Transaction Quick-Add (Roadmap #73/#74):
/// Ausgabe/Einnahme auf ein Konto, Transfer als From/To-Paar.
struct AddTransactionSheet: View {
    let dependencies: AppDependencies
    let onSaved: () -> Void

    @State private var model: AddTransactionModel
    @Environment(\.dismiss) private var dismiss

    /// `editing` gesetzt = bestehende manuelle Buchung bearbeiten.
    init(dependencies: AppDependencies, editing: Transaction? = nil, onSaved: @escaping () -> Void) {
        self.dependencies = dependencies
        self.onSaved = onSaved
        _model = State(initialValue: AddTransactionModel(dependencies: dependencies, editing: editing))
    }

    /// Gleichnamige Konten erhalten ihre Kennung, damit sie im Menü
    /// unterscheidbar sind.
    private func accountTitle(_ account: Account) -> String {
        let sameName = model.accounts.filter { $0.name == account.name }.count
        return sameName > 1 ? "\(account.name) · \(account.presentationIdentifier)" : account.name
    }

    @State private var createsCategory = false

    var body: some View {
        AdaptiveSheet(title: model.isEditing ? String(localized: "Transaktion bearbeiten") : String(localized: "Neue Transaktion")) {
            Form {
                Section("Art") {
                    Picker("Art", selection: $model.draft.kind) {
                        // Beim Bearbeiten bleibt es eine Einzelbuchung, ein
                        // Transfer wäre ein Paar aus zwei Buchungen.
                        ForEach(AddTransactionModel.EntryKind.allCases.filter { !model.isEditing || $0 != .transfer }) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Transaktionsart")
                    .onChange(of: model.draft.kind) { model.dropUnavailableCategory() }
                }

                if model.accounts.isEmpty, !model.isLoading {
                    Section {
                        InlineNotice(
                            message: String(localized: "Eine Transaktion braucht ein Konto. Leg hier ein Bargeld-Konto an oder verbinde später unter „Konten“ deine Bank."),
                            tone: .warning
                        )
                        Button {
                            Task { await model.createCashAccount() }
                        } label: {
                            Label("Bargeld-Konto anlegen", systemImage: "banknote")
                        }
                        .accessibilityHint("Legt ein Konto „Bargeld“ an und wählt es aus")
                    }
                }

                Section("Betrag") {
                    // Titel + Prompt getrennt: Als Titel stünde „0,00" im
                    // macOS-Formular dauerhaft links neben dem Eingabewert.
                    TextField("Betrag", text: $model.draft.amountText, prompt: Text("0,00"))
                        .labelsHidden()
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .font(.title3.monospacedDigit())
                        .accessibilityLabel("Betrag")
                }

                Section("Details") {
                    if model.draft.kind == .transfer {
                        Picker("Von Konto", selection: $model.transferDraft.fromAccountID) {
                            Text("Bitte auswählen").tag(UUID?.none)
                            ForEach(model.accounts) { account in
                                Text(accountTitle(account)).tag(UUID?.some(account.id))
                            }
                        }

                        Picker("Nach Konto", selection: $model.transferDraft.toAccountID) {
                            Text("Bitte auswählen").tag(UUID?.none)
                            ForEach(model.accounts) { account in
                                Text(accountTitle(account)).tag(UUID?.some(account.id))
                            }
                        }
                    } else {
                        TextField("Händler / Beschreibung", text: $model.draft.merchant)

                        Picker("Konto", selection: $model.draft.accountID) {
                            Text("Bitte auswählen").tag(UUID?.none)
                            ForEach(model.accounts) { account in
                                Text(accountTitle(account)).tag(UUID?.some(account.id))
                            }
                        }

                        HStack(spacing: AppSpacing.s) {
                            Picker("Kategorie", selection: $model.draft.categoryID) {
                                Text("Ohne Kategorie").tag(UUID?.none)
                                ForEach(model.categoryOptions) { category in
                                    Label(category.name, systemImage: category.systemIconName)
                                        .tag(UUID?.some(category.id))
                                }
                            }
                            Button {
                                createsCategory = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.borderless)
                            .help("Neue Kategorie anlegen")
                            .accessibilityLabel("Neue Kategorie anlegen")
                        }
                        if let suggested = model.suggestedCategory {
                            Label("Ohne Auswahl wird „\(suggested.name)“ zugeordnet (aus dem Händlernamen).", systemImage: "sparkles")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    DatePicker("Datum", selection: $model.draft.date, displayedComponents: .date)
                }

                if !model.tags.isEmpty {
                    Section("Tags") {
                        ForEach(model.tags) { tag in
                            Button {
                                model.toggleTag(tag.id)
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(tag.colorToken.color)
                                        .frame(width: 8, height: 8)
                                    Text(tag.name)
                                    Spacer()
                                    if model.draft.tagIDs.contains(tag.id) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .accessibilityLabel(
                                model.draft.tagIDs.contains(tag.id)
                                    ? String(localized: "Tag \(tag.name) ausgewählt")
                                    : String(localized: "Tag \(tag.name) nicht ausgewählt")
                            )
                        }
                    }
                }

                Section("Notiz") {
                    TextField("Notiz (optional)", text: $model.draft.note, axis: .vertical)
                        .accessibilityLabel("Notiz")
                }

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppPalette.critical)
                }
            }
            .financeFormStyle()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        Task {
                            if await model.save() {
                                onSaved()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
            .task { await model.load() }
            .sheet(isPresented: $createsCategory) {
                CategoryEditorSheet(
                    dependencies: model.dependenciesForCategoryEditor,
                    editing: nil,
                    onSaved: {},
                    onCreated: { category in model.categoryCreated(category) }
                )
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 600)
        #endif
    }
}
