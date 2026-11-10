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
                switch model.loadState {
                case .idle, .loading:
                    LoadingStateView()
                case .failed(let errorMessage):
                    ErrorStateView(message: errorMessage) {
                        Task { await model.load() }
                    }
                case .loaded:
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
                        value: AppDateFormatter.relativeAge(lastSync)
                    )
                }
            }

            Section {
                if let result = model.balanceResult {
                    LabeledContent(
                        "Aktueller Stand",
                        value: PrivacyAwareMoney.signed(Money(amount: result.amount, currency: model.account.currency), privacy: privacyState)
                    )
                    .fontWeight(.semibold)
                    switch result.basis {
                    case .reported(let source):
                        // Derselbe Stand wie in der Kontenliste: Der von Bank
                        // oder Kontoauszug gemeldete Stand hat Vorrang.
                        if let asOf = LiquidityPresentation.asOfText(
                            basis: result.basis,
                            reportedAt: result.reportedAt,
                            convertedFrom: result.convertedFrom,
                            privacy: privacyState
                        ) {
                            LabeledContent(
                                source == .bank
                                    ? String(localized: "Von der Bank gemeldet")
                                    : String(localized: "Laut Kontoauszug"),
                                value: asOf
                            )
                        }
                    case .openingBalance:
                        if let opening = model.account.openingBalance {
                            LabeledContent(
                                "Anfangsbestand",
                                value: PrivacyAwareMoney.string(Money(amount: opening, currency: model.account.currency), privacy: privacyState)
                                    + (model.account.openingBalanceDate.map { " " + String(localized: "am \(AppDateFormatter.day($0))") } ?? "")
                            )
                        }
                    }
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
                switch model.balanceResult?.basis {
                case nil:
                    Text("Kein aktueller Kontostand. Lege über „Bearbeiten“ einen Anfangsbestand fest.")
                case .reported:
                    Text("Stand = gemeldeter Stand plus spätere Buchungen.")
                case .openingBalance:
                    Text("Stand = Anfangsbestand plus Buchungen ab dem Stichtag.")
                }
            }

            if onDelete != nil {
                Section {
                    Button("Konto löschen …", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                    .accessibilityLabel("Konto \(model.account.name) mit allen Buchungen löschen")
                    .accessibilityIdentifier("account-delete-manual")
                } footer: {
                    Text("Importierte Buchungen lassen sich danach erneut importieren.")
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
