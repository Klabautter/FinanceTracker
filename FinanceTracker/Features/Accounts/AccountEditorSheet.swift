import SwiftUI

/// Konto anlegen oder bearbeiten: Name, Typ, Währung, Anfangsbestand.
/// Bargeld („Geldbeutel") und Konten ohne Anbindung bekommen damit einen
/// echten Kontostand; Buchungen trägt der Nutzer manuell ein oder
/// importiert sie per Datei.
struct AccountEditorSheet: View {
    /// Nur, was dieser Typ nutzt (Roadmap 7.4, `DependencyCapabilities`).
    typealias Dependencies = any HasAccountRepository & HasBaseCurrency & HasChangeTracker

    let dependencies: Dependencies
    let editing: Account?
    let onSaved: () -> Void

    @State private var model: AccountEditorModel
    @Environment(\.dismiss) private var dismiss

    init(
        dependencies: Dependencies,
        editing: Account? = nil,
        transactionCount: Int = 0,
        onSaved: @escaping () -> Void
    ) {
        self.dependencies = dependencies
        self.editing = editing
        self.onSaved = onSaved
        _model = State(initialValue: AccountEditorModel(
            dependencies: dependencies,
            draft: AccountEditorDraft(
                editing: editing,
                transactionCount: transactionCount,
                baseCurrency: dependencies.baseCurrency
            )
        ))
    }

    var body: some View {
        AdaptiveSheet(
            title: editing == nil ? String(localized: "Neues Konto") : String(localized: "Konto bearbeiten"),
            subtitle: editing == nil ? String(localized: "Für Bargeld oder ein Konto ohne Bankanbindung") : nil
        ) {
            Form {
                Section("Konto") {
                    TextField("Name (z. B. Geldbeutel)", text: $model.draft.name)
                        .accessibilityLabel("Kontoname")
                    Picker("Typ", selection: $model.draft.type) {
                        ForEach(AccountType.allCases, id: \.self) { type in
                            Label(type.displayName, systemImage: type.systemImage).tag(type)
                        }
                    }
                    .accessibilityLabel("Kontotyp")
                    Picker("Währung", selection: $model.draft.currency) {
                        ForEach(CurrencyCode.offered, id: \.self) { currency in
                            Text(currency.rawValue).tag(currency)
                        }
                    }
                    .disabled(!model.draft.canChangeCurrency)
                    .accessibilityLabel("Kontowährung")
                    if !model.draft.canChangeCurrency {
                        Text("Die Währung ist festgelegt, weil bereits Buchungen vorhanden sind oder die Bank sie vorgibt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Anfangsbestand festlegen", isOn: $model.draft.hasOpeningBalance)
                        .accessibilityLabel("Anfangsbestand festlegen")
                    if model.draft.hasOpeningBalance {
                        DecimalInputField(title: String(localized: "Anfangsbestand in \(model.draft.currency.rawValue) (z. B. 120)"), value: $model.draft.openingBalance)
                        DatePicker("Stand am", selection: $model.draft.openingBalanceDate, displayedComponents: .date)
                            .accessibilityLabel("Stichtag des Anfangsbestands")
                    }
                } header: {
                    Text("Kontostand")
                } footer: {
                    Text("Der Anfangsbestand ist der Stand zu Beginn des gewählten Tages. Buchungen ab diesem Tag verändern den aktuellen Stand.")
                }

                Section {
                    Toggle("Nicht zum Gesamtstand zählen", isOn: $model.draft.excludedFromTotal)
                        .accessibilityLabel("Konto nicht zum Gesamtstand zählen")
                        .accessibilityIdentifier("account-editor-exclude-total")
                } footer: {
                    Text("Der Stand bleibt beim Konto sichtbar, zählt aber auch nicht zur Reichweite.")
                }

                Section {
                    Toggle("In der Kontenliste ausblenden", isOn: $model.draft.isHiddenInList)
                        .accessibilityLabel("Konto in der Kontenliste ausblenden")
                        .accessibilityIdentifier("account-editor-hide-in-list")
                } footer: {
                    Text("Für Konten, die du nicht mehr nutzt. Buchungen, Stand und Gesamtstand bleiben unverändert; ausgeblendete Konten findest du unten in der Kontenliste.")
                }

                if let errorMessage = model.errorMessage {
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
                    .disabled(!model.draft.canSave || model.isSaving)
                    .accessibilityIdentifier("account-editor-save")
                }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 520)
        #endif
    }

    private func save() async {
        guard await model.save() else { return }
        onSaved()
        dismiss()
    }
}

/// Speichern des Konto-Editors außerhalb des Views (AGENTS.md Regel 1).
@MainActor
@Observable
final class AccountEditorModel {
    /// Nur, was dieses Model nutzt (Roadmap 7.4, `DependencyCapabilities`).
    typealias Dependencies = any HasAccountRepository & HasChangeTracker

    var draft: AccountEditorDraft
    private(set) var errorMessage: String?
    private(set) var isSaving = false
    private let dependencies: Dependencies

    init(dependencies: Dependencies, draft: AccountEditorDraft) {
        self.dependencies = dependencies
        self.draft = draft
    }

    /// `true`, wenn das Konto gespeichert wurde.
    func save() async -> Bool {
        guard draft.canSave else {
            errorMessage = draft.validationMessage
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await dependencies.accountRepository.upsert([draft.makeAccount()])
            dependencies.changeTracker.markChanged()
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(localized: "Das Konto konnte nicht gespeichert werden.")
            return false
        }
    }
}
