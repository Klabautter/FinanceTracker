import SwiftUI

/// „Mit anderen teilen“-Sektion im Transaktionsdetail (P2 Splitwise-light, #27/#28).
///
/// User-Metadaten (#27): Anteile sind Notizen zur bezahlten Transaktion,
/// kein Geldversand (#15 read-only). Ausgleichsvorschläge je Währung
/// (#19/#35) werden ausschließlich als manuelle Transfer-Buchungen
/// (`kind: .transfer`, neutral) angelegt.
struct GroupExpenseSectionView: View {
    let transaction: Transaction
    let dependencies: AppDependencies

    @State private var model: GroupExpenseSectionModel
    @State private var showsAddSheet = false
    @State private var pendingTransfer: SettlementTransfer?
    @State private var bookingNotice: String?
    @Environment(PrivacyPresentationState.self) private var privacyState

    init(transaction: Transaction, dependencies: AppDependencies) {
        self.transaction = transaction
        self.dependencies = dependencies
        _model = State(initialValue: GroupExpenseSectionModel(
            transaction: transaction,
            dependencies: dependencies
        ))
    }

    private var emptySharesHint: some View {
        Text("Noch keine Anteile")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var addFirstShareButton: some View {
        Button("Anteil hinzufügen", systemImage: "plus") {
            showsAddSheet = true
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .accessibilityLabel("Ersten Anteil hinzufügen")
        .accessibilityIdentifier("group-expense-add-empty")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            SectionHeader(
                title: String(localized: "Mit anderen teilen"),
                actionTitle: model.shares.isEmpty ? nil : String(localized: "Hinzufügen"),
                action: model.shares.isEmpty ? nil : { showsAddSheet = true }
            )
            .accessibilityIdentifier("group-expense-header")

            Text("Wer schuldet dir etwas von dieser Ausgabe? Nur eine Notiz, es wird kein Geld versendet.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.isLoading && model.shares.isEmpty {
                // Laden dauert nur einen Augenblick: ruhiger Platzhalter in
                // Knopfhöhe statt eines aufblitzenden Ladekreises.
                Color.clear
                    .frame(height: 24)
                    .accessibilityHidden(true)
            } else if let error = model.errorMessage, model.shares.isEmpty {
                InlineNotice(
                    message: error,
                    title: String(localized: "Anteile konnten nicht geladen werden"),
                    tone: .critical
                )
                Button("Erneut versuchen") {
                    Task { await model.load() }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Anteile erneut laden")
            } else if model.shares.isEmpty {
                // Schmale Detailspalte: Knopf unter den Hinweis statt
                // den Text Buchstabe für Buchstabe umzubrechen.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppSpacing.m) {
                        emptySharesHint
                        Spacer()
                        addFirstShareButton
                    }
                    VStack(alignment: .leading, spacing: AppSpacing.s) {
                        emptySharesHint
                        addFirstShareButton
                    }
                }
            } else {
                sharesList
                Divider()
                balancesPreview
                Divider()
                settlementPreview
            }

            if let bookingNotice {
                InlineNotice(message: bookingNotice, tone: .positive)
                    .accessibilityLabel("Ausgleich gebucht: \(bookingNotice)")
            }

            if let error = model.errorMessage, !model.shares.isEmpty {
                InlineNotice(message: error, tone: .critical)
            }
        }
        .accessibilityIdentifier("group-expense-section")
        .task(id: transaction.id) {
            bookingNotice = nil
            await model.load()
        }
        .sheet(isPresented: $showsAddSheet) {
            GroupExpenseAddShareSheet(
                defaultCurrency: transaction.amount.currency,
                onAdd: { paidBy, owedBy, amountText, currency in
                    let ok = await model.addShare(
                        paidBy: paidBy,
                        owedBy: owedBy,
                        amountText: amountText,
                        currency: currency
                    )
                    return ok
                },
                failureMessage: { model.errorMessage }
            )
        }
        .confirmationDialog(
            "Ausgleich als Transfer buchen?",
            isPresented: Binding(
                get: { pendingTransfer != nil },
                set: { if !$0 { pendingTransfer = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Transfer buchen") {
                guard let transfer = pendingTransfer else { return }
                pendingTransfer = nil
                Task {
                    let ok = await model.bookSettlement(transfer)
                    if ok {
                        let amount = MoneyFormatter.decimalString(transfer.amount, currency: transfer.currency)
                        bookingNotice = String(localized: "\(transfer.from) → \(transfer.to): \(amount) als manuelle Transfer-Buchung angelegt.")
                    }
                }
            }
            .accessibilityLabel("Ausgleich als manuellen Transfer buchen")
            Button("Abbrechen", role: .cancel) {
                pendingTransfer = nil
            }
        } message: {
            if let transfer = pendingTransfer {
                let amount = MoneyFormatter.decimalString(transfer.amount, currency: transfer.currency)
                Text("\(transfer.from) → \(transfer.to): \(amount). Es wird nur eine manuelle Buchung angelegt, kein Geldversand. Die Gegenbuchung ggf. manuell auf dem Absender-Konto anlegen.")
            }
        }
    }

    // MARK: - Anteile

    private var sharesList: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            ForEach(model.shares) { share in
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(share.owedBy) schuldet \(share.paidBy)")
                            .font(.callout)
                            .lineLimit(1)
                        Text(PrivacyAwareMoney.decimalString(
                            share.shareAmount,
                            currency: share.shareCurrency,
                            privacy: privacyState
                        ))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: AppSpacing.s)
                    Toggle(isOn: Binding(
                        get: { share.settled },
                        set: { newValue in
                            Task { await model.setSettled(id: share.id, settled: newValue) }
                        }
                    )) {
                        Text("Erledigt")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(
                        share.settled
                            ? String(localized: "Anteil \(share.owedBy) an \(share.paidBy) als offen markieren")
                            : String(localized: "Anteil \(share.owedBy) an \(share.paidBy) als erledigt markieren")
                    )
                    .accessibilityIdentifier("group-expense-settled-\(share.id.uuidString)")
                    Button(role: .destructive) {
                        Task { await model.deleteShare(id: share.id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Anteil \(share.owedBy) an \(share.paidBy) löschen")
                    .help("Anteil löschen")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(shareAccessibilityLabel(share))
                Divider()
            }

            Button {
                showsAddSheet = true
            } label: {
                Label("Anteil hinzufügen", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Weiteren Anteil hinzufügen")
            .accessibilityIdentifier("group-expense-add")
        }
    }

    // MARK: - Salden je Währung

    private var balancesPreview: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Salden")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if model.sortedCurrencies.isEmpty {
                Text("Keine offenen Anteile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.sortedCurrencies, id: \.rawValue) { currency in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Salden (\(currency.rawValue))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let entries = (model.balances[currency] ?? [:]).sorted { $0.key < $1.key }
                        ForEach(entries, id: \.key) { person, balance in
                            HStack {
                                Text(person)
                                    .font(.callout)
                                Spacer()
                                Text(PrivacyAwareMoney.signed(
                                    Money(amount: balance, currency: currency),
                                    privacy: privacyState
                                ))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(balance < 0 ? AppPalette.critical : AppPalette.positive)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                "\(person): \(PrivacyAwareMoney.accessibilityLabel(balance, currency: currency, privacy: privacyState))"
                            )
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("group-expense-balances")
    }

    // MARK: - Ausgleich

    private var settlementPreview: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Ausgleichsvorschlag")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if model.transfers.isEmpty {
                Text("Alles ausgeglichen, kein Transfer nötig.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Kein Ausgleich nötig")
            } else {
                // #15 read-only: Ausgleich ist eine manuelle Transfer-Buchung,
                // das Zielkonto wählt der Nutzer (Default: Transaktionskonto),
                // es wird nichts automatisch versendet oder umgebucht.
                if !model.availableAccounts.isEmpty {
                    Picker("Zielkonto für Ausgleich", selection: Binding(
                        get: { model.settlementAccountID ?? transaction.accountID },
                        set: { model.settlementAccountID = $0 }
                    )) {
                        if !model.availableAccounts.contains(where: { $0.id == transaction.accountID }) {
                            Text("Transaktionskonto").tag(transaction.accountID)
                        }
                        ForEach(model.availableAccounts) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Zielkonto für die Ausgleichsbuchung")
                    .accessibilityIdentifier("group-expense-settlement-account")
                    Text("Die Ausgleichsbuchung wird manuell auf dem gewählten Konto angelegt, kein Geldversand.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(model.transfers.enumerated()), id: \.offset) { _, transfer in
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(transfer.from) → \(transfer.to)")
                                .font(.callout)
                            Text(PrivacyAwareMoney.decimalString(
                                transfer.amount,
                                currency: transfer.currency,
                                privacy: privacyState
                            ))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: AppSpacing.s)
                        Button("Als Transfer buchen") {
                            pendingTransfer = transfer
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(settlementAccessibilityLabel(transfer))
                        .accessibilityIdentifier(
                            "group-expense-settle-\(transfer.from)-\(transfer.to)-\(transfer.currency.rawValue)"
                        )
                    }
                    .accessibilityElement(children: .contain)
                }
                Text("Buchungen sind manuell und Cashflow-neutral, es wird kein Geld versendet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("group-expense-settlement")
    }

    private func shareAccessibilityLabel(_ share: SharedExpenseShare) -> String {
        let amount = PrivacyAwareMoney.accessibilityLabel(
            share.shareAmount,
            currency: share.shareCurrency,
            privacy: privacyState
        )
        return share.settled
            ? String(localized: "Anteil: \(share.owedBy) schuldet \(share.paidBy), \(amount), erledigt")
            : String(localized: "Anteil: \(share.owedBy) schuldet \(share.paidBy), \(amount), offen")
    }

    private func settlementAccessibilityLabel(_ transfer: SettlementTransfer) -> String {
        let amount = PrivacyAwareMoney.accessibilityLabel(
            transfer.amount,
            currency: transfer.currency,
            privacy: privacyState
        )
        return String(localized: "Ausgleich \(transfer.from) an \(transfer.to) über \(amount) als manuellen Transfer buchen")
    }
}

/// Eingabe-Sheet für einen Anteil (Nutzer-Metadaten, #27).
private struct GroupExpenseAddShareSheet: View {
    let defaultCurrency: CurrencyCode
    /// Liefert true bei Erfolg (Sheet schließt), false lässt das Sheet
    /// offen, die Fehlermeldung steht dann im aufrufenden Model.
    let onAdd: (_ paidBy: String, _ owedBy: String, _ amountText: String, _ currency: CurrencyCode) async -> Bool
    /// Der konkrete Grund, wenn `onAdd` scheitert (z. B. Anteil zu hoch).
    var failureMessage: () -> String? = { nil }

    @Environment(\.dismiss) private var dismiss
    /// Meist hat man selbst gezahlt, vorbelegt mit dem zuletzt verwendeten
    /// Zahler, beim ersten Mal „Ich“.
    @AppStorage("groupExpense.lastPayer") private var lastPayer = String(localized: "Ich")
    @State private var paidBy = ""
    @State private var owedBy = ""
    @State private var amountText = ""
    @State private var currency: CurrencyCode = .eur
    @State private var isSaving = false
    @State private var localError: String?

    private static let offeredCurrencies: [CurrencyCode] = CurrencyCode.offered

    init(
        defaultCurrency: CurrencyCode,
        onAdd: @escaping (_ paidBy: String, _ owedBy: String, _ amountText: String, _ currency: CurrencyCode) async -> Bool,
        failureMessage: @escaping () -> String? = { nil }
    ) {
        self.defaultCurrency = defaultCurrency
        self.onAdd = onAdd
        self.failureMessage = failureMessage
        _currency = State(initialValue: Self.offeredCurrencies.contains(defaultCurrency) ? defaultCurrency : .eur)
        _paidBy = State(initialValue: UserDefaults.standard.string(forKey: "groupExpense.lastPayer") ?? String(localized: "Ich"))
    }

    var body: some View {
        FormSheetScaffold(
            title: String(localized: "Anteil hinzufügen"),
            subtitle: String(localized: "Wer hat bezahlt, und wer schuldet welchen Anteil?"),
            systemImage: "person.2"
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.m) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Bezahlt von")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("z. B. Ich", text: $paidBy)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Zahler, Name")
                        .accessibilityIdentifier("group-expense-paidby")
                }
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Schuldet den Anteil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("z. B. Mara", text: $owedBy)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Schuldner, Name")
                        .accessibilityIdentifier("group-expense-owedby")
                }
                HStack(spacing: AppSpacing.m) {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Anteil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("0,00", text: $amountText)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                            .accessibilityLabel("Anteil, Betrag")
                            .accessibilityIdentifier("group-expense-amount")
                    }
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Währung")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Währung", selection: $currency) {
                            ForEach(Self.offeredCurrencies, id: \.rawValue) { code in
                                Text(code.rawValue).tag(code)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityLabel("Währung des Anteils")
                        .accessibilityIdentifier("group-expense-currency")
                    }
                }
                if let localError {
                    InlineNotice(message: localError, tone: .critical)
                }
            }
        } actions: {
            Button("Abbrechen") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Hinzufügen abbrechen")
            Button("Hinzufügen") {
                Task {
                    await save()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving || paidBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || owedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Anteil speichern")
            .accessibilityIdentifier("group-expense-save")
        }
        .accessibilityIdentifier("group-expense-add-sheet")
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        localError = nil
        defer { isSaving = false }
        let ok = await onAdd(paidBy, owedBy, amountText, currency)
        if ok {
            lastPayer = paidBy.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ok {
            dismiss()
        } else {
            localError = failureMessage() ?? String(localized: "Anteil konnte nicht gespeichert werden. Eingaben prüfen.")
        }
    }
}
