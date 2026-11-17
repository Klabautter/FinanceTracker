import SwiftUI

/// Recurring-Detail (Roadmap #115): Bearbeiten, Pausieren, letzte
/// Zahlungen, manuelle Zuordnung (#110), Löschen.
struct FixkostenDetailSheet: View {
    let dependencies: AppDependencies
    let onChanged: () -> Void

    @State private var model: FixkostenDetailModel
    @State private var showsDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss

    init(commitment: RecurringCommitment, dependencies: AppDependencies, onChanged: @escaping () -> Void) {
        self.dependencies = dependencies
        self.onChanged = onChanged
        _model = State(initialValue: FixkostenDetailModel(commitment: commitment, dependencies: dependencies))
    }

    var body: some View {
        AdaptiveSheet(title: model.direction == .expense ? String(localized: "Zahlungsplan bearbeiten") : String(localized: "Einnahme bearbeiten")) {
            Form {
                Section {
                    TextField("Name", text: $model.name)
                    DecimalInputField(title: String(localized: "Betrag"), value: $model.amount)
                    Picker("Richtung", selection: $model.direction) {
                        ForEach(RecurringCommitment.Direction.allCases, id: \.self) { direction in
                            Text(direction.displayName).tag(direction)
                        }
                    }
                    Picker("Turnus", selection: $model.cadence) {
                        ForEach(RecurringCommitment.Cadence.allCases, id: \.self) { cadence in
                            Text(cadence.displayName).tag(cadence)
                        }
                    }
                    Toggle("Termin geplant", isOn: $model.hasNextExpectedDate)
                    if model.hasNextExpectedDate {
                        DatePicker(
                            selection: $model.nextExpectedDate,
                            displayedComponents: .date
                        ) {
                            model.direction == .expense ? Text("Nächste Fälligkeit") : Text("Nächster Eingang")
                        }
                    }
                    CategorySelectionPicker(
                        title: String(localized: "Kategorie"),
                        selection: $model.categoryID,
                        categories: model.leafCategories,
                        dependencies: dependencies
                    )
                } header: {
                    model.direction == .expense ? Text("Zahlungsplan") : Text("Wiederkehrende Einnahme")
                }

                Section {
                    Toggle("Pausiert", isOn: Binding(
                        get: { model.isPaused },
                        set: { newValue in
                            Task {
                                await model.persistStatus(newValue ? .paused : .active)
                                onChanged()
                            }
                        }
                    ))
                    .accessibilityLabel("Wiederkehrenden Eintrag pausieren oder aktivieren")
                    .accessibilityIdentifier("recurring-detail-pause")
                    .disabled(model.isUpdatingStatus)
                } footer: {
                    Text("Pausieren wird sofort gespeichert.")
                }

                Section("Letzte Zahlungen") {
                    if model.paidTransactions.isEmpty {
                        Text("Keine Zahlungen gefunden.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.paidTransactions.prefix(5)) { txn in
                            HStack {
                                Text(AppDateFormatter.day(txn.displayDate))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(txn.effectiveMerchantName)
                                    .lineLimit(1)
                                Spacer()
                                MoneyText(money: Money(amount: abs(txn.amount.amount), currency: txn.amount.currency))
                                    .font(.callout.monospacedDigit())
                                // WP5: Explizite Zuordnungen sind entfernbar;
                                // danach greift Heuristik-Fallback bzw. offen.
                                if model.explicitlyAssignedIDs.contains(txn.id) {
                                    Button {
                                        Task { await model.unassign(transactionID: txn.id) }
                                    } label: {
                                        Label("Zuordnung entfernen", systemImage: "xmark.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Zuordnung von \(txn.effectiveMerchantName) entfernen")
                                }
                            }
                        }
                    }

                    // Manuelle Zuordnung (#110)
                    if model.showsAssignList {
                        ForEach(model.unassignedTransactions.prefix(8)) { txn in
                            Button {
                                Task { await model.assign(txn) }
                            } label: {
                                HStack {
                                    Text(AppDateFormatter.day(txn.displayDate))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(txn.effectiveMerchantName)
                                        .lineLimit(1)
                                    Spacer()
                                    MoneyText(money: txn.amount, signed: true)
                                        .font(.caption.monospacedDigit())
                                }
                            }
                        }
                        Button("Zuordnen abbrechen") { model.showsAssignList = false }
                            .font(.caption)
                    } else {
                        Button("Transaktion manuell zuordnen…") {
                            model.showsAssignList = true
                        }
                        .font(.caption)
                    }
                }

                if let errorMessage = model.loadState.failureMessage ?? model.actionError {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppPalette.critical)
                }

                Section {
                    Button("Nicht mehr wiederkehrend (löschen)", role: .destructive) {
                        showsDeleteConfirmation = true
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
                }
                ToolbarItem(placement: .confirmationAction) {
                    // WP5 (§36-37): Sheet schließt erst NACH bestätigter
                    // Persistenz; Fehlschlag lässt das Sheet offen und zeigt
                    // den Fehler (kein Setzen einer ErrorMessage im bereits
                    // geschlossenen Sheet).
                    Button("Speichern") {
                        Task {
                            guard await model.persist() else { return }
                            onChanged()
                            dismiss()
                        }
                    }
                    .disabled(model.isSaving || model.isUpdatingStatus || !model.canSave)
                }
            }
            .confirmationDialog(
                "Wiederkehrenden Eintrag löschen?",
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Endgültig löschen", role: .destructive) {
                    Task {
                        guard await model.deleteCommitment() else { return }
                        onChanged()
                        dismiss()
                    }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Der Eintrag und seine Zuordnungen zu Transaktionen werden entfernt.")
            }
            .task { await model.load() }
        }
        #if os(macOS)
        .frame(
            minWidth: 440,
            idealWidth: 500,
            maxWidth: 600,
            minHeight: 420,
            idealHeight: 560,
            maxHeight: 680
        )
        #endif
    }
}

/// Formular, Zahlungen und Zuordnungen eines Zahlungsplans (AGENTS.md
/// Regeln 1 und 37).
@MainActor
@Observable
final class FixkostenDetailModel {
    private(set) var commitment: RecurringCommitment
    var name: String
    /// WP5 (§35): Typed Decimal statt Display-String als Edit-State.
    var amount: Decimal?
    var categoryID: UUID?
    var direction: RecurringCommitment.Direction
    var cadence: RecurringCommitment.Cadence
    var hasNextExpectedDate: Bool
    var nextExpectedDate: Date
    var showsAssignList = false
    private(set) var leafCategories: [Category] = []
    private(set) var paidTransactions: [Transaction] = []
    private(set) var explicitlyAssignedIDs: Set<UUID> = []
    private(set) var unassignedTransactions: [Transaction] = []
    private(set) var loadState: LoadState = .idle
    private(set) var actionError: String?
    /// WP5 (§37): Save-Flow mit Persistenz-Bestätigung vor dem Dismiss.
    private(set) var isSaving = false
    private(set) var isUpdatingStatus = false
    private var explicitOccurrences: [RecurringOccurrence] = []
    private let dependencies: AppDependencies

    init(commitment: RecurringCommitment, dependencies: AppDependencies) {
        self.commitment = commitment
        self.dependencies = dependencies
        // WP5 (§35): Rohwert ohne Währungssymbol; Display-Formatting und
        // Edit-Input sind getrennt.
        name = commitment.name
        amount = commitment.expectedAmount
        categoryID = commitment.categoryID
        direction = commitment.direction
        cadence = commitment.cadence
        hasNextExpectedDate = commitment.nextExpectedDate != nil
        nextExpectedDate = commitment.nextExpectedDate ?? Date()
    }

    var isPaused: Bool { commitment.status == .paused }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (amount ?? 0) > 0
    }

    /// Kategorien und Zahlungen. Die Formularfelder stammen aus dem
    /// Zahlungsplan selbst und werden hier nicht überschrieben.
    func load() async {
        loadState = .loading
        do {
            let all = try await dependencies.categoryRepository.categories()
            leafCategories = all
                .filter { category in !all.contains { $0.parentID == category.id } }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            loadState = .failed(String(localized: "Kategorien konnten nicht geladen werden."))
            return
        }
        do {
            try await loadPayments()
            loadState = .loaded
        } catch {
            loadState = .failed(String(localized: "Zahlungen konnten nicht geladen werden."))
        }
    }

    private func loadPayments() async throws {
        async let monthTxnsTask = dependencies.transactionRepository.transactions(matching: Self.recentMatchingHistoryQuery())
        async let occurrencesTask = dependencies.recurringCommitmentRepository.occurrences(commitmentID: commitment.id)
        let monthTxns = try await monthTxnsTask
        let occurrences = try await occurrencesTask
        explicitOccurrences = occurrences

        // WP7 (§60): Das Recurring-Detail nutzt dieselbe Occurrence-
        // Resolution wie Fixkosten-Übersicht und Forecast.
        let resolution = RecurringOccurrenceResolver().resolveOccurrences(
            commitment: commitment,
            explicitOccurrences: occurrences,
            allTransactions: monthTxns,
            period: DateInterval(
                start: monthTxns.map(\.displayDate).min() ?? .distantPast,
                end: Date()
            ),
            calendar: Calendar.current
        )
        paidTransactions = resolution.paidTransactions.sorted { $0.displayDate > $1.displayDate }
        explicitlyAssignedIDs = Set(
            resolution.scheduled
                .filter { $0.matchOrigin == .explicitUserAssignment }
                .compactMap(\.matchedTransactionID)
        )
        let paidIDs = Set(paidTransactions.map(\.id))
        unassignedTransactions = monthTxns
            .filter { !paidIDs.contains($0.id) }
            .sorted { $0.displayDate > $1.displayDate }
    }

    /// WP5 (§112): Benennung nach Funktion, nicht nach gelogener Dauer.
    private static func recentMatchingHistoryQuery() -> TransactionQuery {
        var query = TransactionQuery()
        if let start = Calendar.current.date(byAdding: .day, value: -45, to: Date()) {
            query.dateInterval = DateInterval(start: start, end: Date())
        }
        return query
    }

    /// WP5 (§37/§38): Persistiert die Änderungen; `false` bei ungültiger
    /// Eingabe oder Repository-Fehler; das Sheet bleibt in dem Fall offen.
    func persist() async -> Bool {
        // §38: Ungültige Eingabe blockiert den Save sichtbar: der alte
        // Betrag wird nicht still beibehalten und auch nicht mit anderen
        // Änderungen zusammen eingespeichert.
        guard let amount, amount > 0 else {
            actionError = String(localized: "Bitte einen gültigen positiven Betrag eingeben.")
            return false
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            actionError = String(localized: "Bitte einen Namen eingeben.")
            return false
        }
        let draft = RecurringCommitmentDraft(
            name: trimmedName,
            direction: direction,
            cadence: cadence,
            categoryID: categoryID,
            nextExpectedDate: hasNextExpectedDate ? nextExpectedDate : nil,
            amount: amount
        )
        let updated = draft.applying(to: commitment)
        isSaving = true
        defer { isSaving = false }
        do {
            try await dependencies.recurringCommitmentRepository.upsert([updated])
            commitment = updated
            dependencies.changeTracker.markChanged()
            actionError = nil
            return true
        } catch {
            actionError = String(localized: "Speichern fehlgeschlagen.")
            return false
        }
    }

    /// Pausieren wird sofort gespeichert.
    func persistStatus(_ status: RecurringCommitment.Status) async {
        guard status != commitment.status else { return }
        isUpdatingStatus = true
        defer { isUpdatingStatus = false }
        let updated = RecurringCommitmentDraft.changingStatus(in: commitment, to: status)
        do {
            try await dependencies.recurringCommitmentRepository.upsert([updated])
            commitment = updated
            dependencies.changeTracker.markChanged()
            actionError = nil
        } catch {
            actionError = String(localized: "Status konnte nicht gespeichert werden.")
        }
    }

    /// `true`, wenn der Zahlungsplan gelöscht wurde.
    func deleteCommitment() async -> Bool {
        do {
            try await dependencies.recurringCommitmentRepository.delete(id: commitment.id)
            dependencies.changeTracker.markChanged()
            return true
        } catch {
            actionError = String(localized: "Löschen fehlgeschlagen.")
            return false
        }
    }

    func assign(_ txn: Transaction) async {
        do {
            try await dependencies.recurringCommitmentRepository.addOccurrence(
                RecurringOccurrence(commitmentID: commitment.id, transactionID: txn.id)
            )
            dependencies.changeTracker.markChanged()
            try await loadPayments()
            actionError = nil
        } catch {
            // WP5: Persistenz-Fehler werden nie geschluckt: der Nutzer
            // sieht, dass die Zuordnung nicht gespeichert wurde.
            actionError = String(localized: "Zuordnung konnte nicht gespeichert werden. Bitte erneut versuchen.")
        }
    }

    func unassign(transactionID: UUID) async {
        do {
            guard let occurrence = explicitOccurrences.first(where: { $0.transactionID == transactionID }) else { return }
            try await dependencies.recurringCommitmentRepository.removeOccurrence(id: occurrence.id)
            dependencies.changeTracker.markChanged()
            try await loadPayments()
            actionError = nil
        } catch {
            actionError = String(localized: "Zuordnung konnte nicht entfernt werden. Bitte erneut versuchen.")
        }
    }
}

struct RecurringCommitmentDraft {
    var name: String
    var direction: RecurringCommitment.Direction
    var cadence: RecurringCommitment.Cadence
    var categoryID: UUID?
    var nextExpectedDate: Date?
    var amount: Decimal
    /// Optional gewählter Händler; ohne ihn passt der Plan nur über den Betrag.
    var merchantKey: String? = nil

    func newCommitment(currency: CurrencyCode, now: Date = Date()) -> RecurringCommitment {
        RecurringCommitment(
            name: name,
            merchantKey: merchantKey,
            direction: direction,
            cadence: cadence,
            amountPolicy: .fixed,
            expectedAmount: amount,
            currency: currency,
            categoryID: categoryID,
            nextExpectedDate: nextExpectedDate,
            status: .active,
            origin: .manual,
            createdAt: now,
            updatedAt: now
        )
    }

    func applying(to commitment: RecurringCommitment, now: Date = Date()) -> RecurringCommitment {
        var updated = commitment
        updated.name = name
        updated.direction = direction
        updated.cadence = cadence
        updated.categoryID = categoryID
        updated.nextExpectedDate = nextExpectedDate
        updated.expectedAmount = amount
        updated.updatedAt = now
        return updated
    }

    static func changingStatus(
        in commitment: RecurringCommitment,
        to status: RecurringCommitment.Status,
        now: Date = Date()
    ) -> RecurringCommitment {
        var updated = commitment
        updated.status = status
        updated.updatedAt = now
        return updated
    }
}
