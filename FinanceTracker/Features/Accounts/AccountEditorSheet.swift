import SwiftUI

/// Konto anlegen oder bearbeiten: Name, Typ, Währung, Anfangsbestand.
/// Bargeld („Geldbeutel") und Konten ohne Anbindung bekommen damit einen
/// echten Kontostand; Buchungen trägt der Nutzer manuell ein oder
/// importiert sie per Datei.
struct AccountEditorSheet: View {
    let dependencies: AppDependencies
    let editing: Account?
    let onSaved: () -> Void

    @State private var draft: AccountEditorDraft
    @State private var errorMessage: String?
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(
        dependencies: AppDependencies,
        editing: Account? = nil,
        transactionCount: Int = 0,
        onSaved: @escaping () -> Void
    ) {
        self.dependencies = dependencies
        self.editing = editing
        self.onSaved = onSaved
        _draft = State(initialValue: AccountEditorDraft(
            editing: editing,
            transactionCount: transactionCount,
            baseCurrency: dependencies.baseCurrency
        ))
    }

    var body: some View {
        AdaptiveSheet(
            title: editing == nil ? String(localized: "Neues Konto") : String(localized: "Konto bearbeiten"),
            subtitle: editing == nil ? String(localized: "Für Bargeld oder ein Konto ohne Bankanbindung") : nil
        ) {
            Form {
                Section("Konto") {
                    TextField("Name (z. B. Geldbeutel)", text: $draft.name)
                        .accessibilityLabel("Kontoname")
                    Picker("Typ", selection: $draft.type) {
                        ForEach(AccountType.allCases, id: \.self) { type in
                            Label(type.displayName, systemImage: type.systemImage).tag(type)
                        }
                    }
                    .accessibilityLabel("Kontotyp")
                    Picker("Währung", selection: $draft.currency) {
                        ForEach(CurrencyCode.offered, id: \.self) { currency in
                            Text(currency.rawValue).tag(currency)
                        }
                    }
                    .disabled(!draft.canChangeCurrency)
                    .accessibilityLabel("Kontowährung")
                    if !draft.canChangeCurrency {
                        Text("Die Währung ist festgelegt, weil bereits Buchungen vorhanden sind oder die Bank sie vorgibt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Anfangsbestand festlegen", isOn: $draft.hasOpeningBalance)
                        .accessibilityLabel("Anfangsbestand festlegen")
                    if draft.hasOpeningBalance {
                        DecimalInputField(title: String(localized: "Anfangsbestand in \(draft.currency.rawValue) (z. B. 120)"), value: $draft.openingBalance)
                        DatePicker("Stand am", selection: $draft.openingBalanceDate, displayedComponents: .date)
                            .accessibilityLabel("Stichtag des Anfangsbestands")
                    }
                } header: {
                    Text("Kontostand")
                } footer: {
                    Text("Der Anfangsbestand ist der Stand zu Beginn des gewählten Tages. Buchungen ab diesem Tag verändern den aktuellen Stand. Er zählt nicht als Einnahme und verändert keine Auswertung.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AppPalette.warning)
                    }
                }
            }
            .financeFormStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? String(localized: "Anlegen") : String(localized: "Speichern")) {
                        Task { await save() }
                    }
                    .disabled(!draft.canSave || isSaving)
                    .accessibilityIdentifier("account-editor-save")
                }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 520)
        #endif
    }

    private func save() async {
        guard draft.canSave else {
            errorMessage = draft.validationMessage
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await dependencies.accountRepository.upsert([draft.makeAccount()])
            dependencies.changeTracker.markChanged()
            onSaved()
            dismiss()
        } catch {
            errorMessage = String(localized: "Das Konto konnte nicht gespeichert werden.")
        }
    }
}
