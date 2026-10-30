import SwiftUI

/// Account-Detail (Roadmap #136–138): Quelle, Sync-Status, Währung,
/// Netto-Bewegung und die letzten Transaktionen.
struct AccountDetailSheet: View {
    let account: Account
    let connectionName: String?
    let lastSync: Date?
    let dependencies: AppDependencies
    /// Gesetzt = Konto ist löschbar (manuell angelegt). Führt die Löschung aus.
    let onDelete: (@MainActor () async -> Void)?

    @State private var model: AccountDetailModel
    @State private var showsEditor = false
    @State private var showsDeleteConfirmation = false

    init(
        account: Account,
        connectionName: String?,
        lastSync: Date?,
        dependencies: AppDependencies,
        onDelete: (@MainActor () async -> Void)? = nil
    ) {
        self.account = account
        self.connectionName = connectionName
        self.lastSync = lastSync
        self.dependencies = dependencies
        self.onDelete = onDelete
        _model = State(initialValue: AccountDetailModel(account: account, dependencies: dependencies))
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyPresentationState.self) private var privacyState

    private var editPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .cancellationAction
        #else
        .primaryAction
        #endif
    }

    var body: some View {
        AdaptiveSheet(title: model.account.name) {
            Group {
                if model.isLoading {
                    LoadingStateView()
                } else if let errorMessage = model.errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await model.load() }
                    }
                } else {
                    content
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // macOS-Sheets ohne NavigationStack zeigen nur Dialogleisten-
                // Placements; `.primaryAction` würde dort nicht gerendert.
                ToolbarItem(placement: editPlacement) {
                    Button("Bearbeiten") { showsEditor = true }
                        .accessibilityLabel("Konto bearbeiten")
                        .help("Name, Typ oder Anfangsbestand ändern")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showsEditor) {
            AccountEditorSheet(
                dependencies: dependencies,
                editing: model.account,
                transactionCount: model.transactionCount,
                onSaved: { Task { await model.load() } }
            )
        }
        .alert("Konto und Buchungen löschen?", isPresented: $showsDeleteConfirmation) {
            Button("Konto löschen", role: .destructive) {
                Task {
                    await onDelete?()
                    dismiss()
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("„\(model.account.name)“ wird mit \(model.transactionCount) Buchungen und deren Belegen endgültig entfernt. Das lässt sich nicht rückgängig machen.")
        }
        .task { await model.load() }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
    }

    private var content: some View {
        Form {
            Section("Konto") {
                LabeledContent("Typ", value: model.account.type.displayName)
                LabeledContent("Kennung", value: model.account.presentationIdentifier)
                LabeledContent("Währung", value: model.account.currency.rawValue)
                if let connectionName {
                    LabeledContent("Quelle", value: connectionName)
                }
                if let lastSync {
                    LabeledContent(
                        "Letzte Aktualisierung",
                        value: lastSync.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
                    )
                }
            }

            Section {
                if let balance = model.balance, let opening = model.account.openingBalance {
                    LabeledContent(
                        "Aktueller Stand",
                        value: PrivacyAwareMoney.signed(Money(amount: balance, currency: model.account.currency), privacy: privacyState)
                    )
                    .fontWeight(.semibold)
                    LabeledContent(
                        "Anfangsbestand",
                        value: PrivacyAwareMoney.string(Money(amount: opening, currency: model.account.currency), privacy: privacyState)
                            + (model.account.openingBalanceDate.map { " " + String(localized: "am \(AppDateFormatter.day($0))") } ?? "")
                    )
                }
                LabeledContent(
                    "Summe der Transaktionen",
                    value: PrivacyAwareMoney.signed(Money(amount: model.netMovement, currency: model.account.currency), privacy: privacyState)
                )
                LabeledContent("Transaktionen", value: "\(model.transactionCount)")
                if !model.foreignCurrencies.isEmpty {
                    LabeledContent(
                        "Fremdwährungen",
                        value: model.foreignCurrencies.map(\.rawValue).sorted().joined(separator: ", ")
                    )
                }
            } header: {
                Text("Erfasste Transaktionen")
            } footer: {
                model.balance == nil
                    ? Text("Kein aktueller Kontostand. Lege über „Bearbeiten“ einen Anfangsbestand fest. Fremdwährungen werden getrennt ausgewiesen.")
                    : Text("Stand = Anfangsbestand plus Buchungen ab dem Stichtag. Fremdwährungen werden getrennt ausgewiesen.")
            }

            if onDelete != nil {
                Section {
                    Button("Konto löschen …", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                    .accessibilityLabel("Konto \(model.account.name) mit allen Buchungen löschen")
                    .accessibilityIdentifier("account-delete-manual")
                } footer: {
                    Text("Entfernt dieses selbst angelegte Konto samt seiner Buchungen. Importierte Buchungen lassen sich danach erneut importieren.")
                }
            }

            Section("Letzte Transaktionen") {
                if model.transactions.isEmpty {
                    Text("Keine Transaktionen gefunden.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.transactions) { txn in
                        TransactionRowView(transaction: txn, category: model.category(for: txn))
                            .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .financeFormStyle()
    }

}
