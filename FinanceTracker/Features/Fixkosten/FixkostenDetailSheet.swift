import SwiftUI

/// Recurring-Detail (Roadmap #115): Bearbeiten, Pausieren, letzte
/// Zahlungen, manuelle Zuordnung (#110), Löschen.
struct FixkostenDetailSheet: View {
    @State private var commitment: RecurringCommitment
    let dependencies: AppDependencies
    let onChanged: () -> Void

    @State private var name = ""
    /// WP5 (§35): Typed Decimal statt Display-String als Edit-State.
    @State private var amount: Decimal?
    @State private var categoryID: UUID?
    @State private var direction: RecurringCommitment.Direction = .expense
    @State private var cadence: RecurringCommitment.Cadence = .monthly
    @State private var hasNextExpectedDate = false
    @State private var nextExpectedDate = Date()
    @State private var leafCategories: [Category] = []
    @State private var paidTransactions: [Transaction] = []
    @State private var explicitlyAssignedIDs: Set<UUID> = []
    @State private var unassignedTransactions: [Transaction] = []
    @State private var showsAssignList = false
    @State private var errorMessage: String?
    /// WP5 (§37): Save-Flow mit Persistenz-Bestätigung vor dem Dismiss.
    @State private var isSaving = false
    @State private var isUpdatingStatus = false
    @State private var showsDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss

    private var isPaused: Bool { commitment.status == .paused }

    init(commitment: RecurringCommitment, dependencies: AppDependencies, onChanged: @escaping () -> Void) {
        _commitment = State(initialValue: commitment)
        self.dependencies = dependencies
        self.onChanged = onChanged
    }

    var body: some View {
        AdaptiveSheet(title: direction == .expense ? String(localized: "Zahlungsplan bearbeiten") : String(localized: "Einnahme bearbeiten")) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    DecimalInputField(title: String(localized: "Betrag"), value: $amount)
                    Picker("Richtung", selection: $direction) {
                        ForEach(RecurringCommitment.Direction.allCases, id: \.self) { direction in
                            Text(direction.displayName).tag(direction)
                        }
                    }
                    Picker("Turnus", selection: $cadence) {
                        ForEach(RecurringCommitment.Cadence.allCases, id: \.self) { cadence in
                            Text(cadence.displayName).tag(cadence)
                        }
                    }
                    Toggle("Termin geplant", isOn: $hasNextExpectedDate)
                    if hasNextExpectedDate {
                        DatePicker(
                            selection: $nextExpectedDate,
                            displayedComponents: .date
                        ) {
                            direction == .expense ? Text("Nächste Fälligkeit") : Text("Nächster Eingang")
                        }
                    }
                    CategorySelectionPicker(
                        title: String(localized: "Kategorie"),
                        selection: $categoryID,
                        categories: leafCategories,
                        dependencies: dependencies
                    )
                } header: {
                    direction == .expense ? Text("Zahlungsplan") : Text("Wiederkehrende Einnahme")
                }

                Section {
                    Toggle("Pausiert", isOn: Binding(
                        get: { isPaused },
                        set: { newValue in
                            Task {
                                await persistStatus(newValue ? .paused : .active)
                            }
                        }
                    ))
                    .accessibilityLabel("Wiederkehrenden Eintrag pausieren oder aktivieren")
                    .accessibilityIdentifier("recurring-detail-pause")
                    .disabled(isUpdatingStatus)
                } footer: {
                    Text("Pausieren ändert nur den Status. Offene Formularänderungen werden erst mit „Speichern“ übernommen.")
                }

                Section("Letzte Zahlungen") {
                    if paidTransactions.isEmpty {
                        Text("Keine Zahlungen gefunden.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(paidTransactions.prefix(5)) { txn in
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
                                if explicitlyAssignedIDs.contains(txn.id) {
                                    Button {
                                        Task {
                                            if let occurrence = await occurrence(for: txn.id) {
                                                await unassign(occurrence)
                                            }
                                        }
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
                    if showsAssignList {
                        ForEach(unassignedTransactions.prefix(8)) { txn in
                            Button {
                                Task { await assign(txn) }
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
                        Button("Zuordnen abbrechen") { showsAssignList = false }
                            .font(.caption)
                    } else {
                        Button("Transaktion manuell zuordnen…") {
                            showsAssignList = true
                        }
                        .font(.caption)
                    }
                }

                if let errorMessage {
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
                            isSaving = true
                            defer { isSaving = false }
                            guard await persist() else { return }
                            dismiss()
                        }
                    }
                    .disabled(isSaving || isUpdatingStatus || !canSave)
                }
            }
            .confirmationDialog(
                "Wiederkehrenden Eintrag löschen?",
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Endgültig löschen", role: .destructive) {
                    Task { await deleteCommitment() }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Der Eintrag und seine Zuordnungen zu Transaktionen werden entfernt.")
            }
            .task { await load() }
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

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && amount != nil
            && amount! > 0
    }

    private func load() async {
        name = commitment.name
        // WP5 (§35): Rohwert ohne Währungssymbol; Display-Formatting und
        // Edit-Input sind getrennt.
        amount = commitment.expectedAmount
        categoryID = commitment.categoryID
        direction = commitment.direction
        cadence = commitment.cadence
        hasNextExpectedDate = commitment.nextExpectedDate != nil
        nextExpectedDate = commitment.nextExpectedDate ?? Date()

        do {
            let all = try await dependencies.categoryRepository.categories()
            leafCategories = all
                .filter { category in !all.contains { $0.parentID == category.id } }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = String(localized: "Kategorien konnten nicht geladen werden.")
        }

        do {
            async let monthTxnsTask = dependencies.transactionRepository.transactions(matching: recentMatchingHistoryQuery())
            async let occurrencesTask = dependencies.recurringCommitmentRepository.occurrences(commitmentID: commitment.id)

            let monthTxns = try await monthTxnsTask
            let occurrences = try await occurrencesTask

            // WP7 (§60): Das Recurring-Detail nutzt dieselbe Occurrence-
            // Resolution wie Fixkosten-Übersicht und Forecast.
            let resolver = RecurringOccurrenceResolver()
            let resolution = resolver.resolveOccurrences(
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
        } catch {
            errorMessage = String(localized: "Zahlungen konnten nicht geladen werden.")
        }
    }
    /// WP5 (§112): Benennung nach Funktion, nicht nach gelogener Dauer.
    private func recentMatchingHistoryQuery() -> TransactionQuery {
        var query = TransactionQuery()
        let calendar = Calendar.current
        if let start = calendar.date(byAdding: .day, value: -45, to: Date()) {
            query.dateInterval = DateInterval(start: start, end: Date())
        }
        return query
    }

    /// WP5 (§37/§38): Persistiert die Änderungen; `false` bei ungültiger
    /// Eingabe oder Repository-Fehler; das Sheet bleibt in dem Fall offen.
    @discardableResult
    private func persist() async -> Bool {
        // §38: Ungültige Eingabe blockiert den Save sichtbar: der alte
        // Betrag wird nicht still beibehalten und auch nicht mit anderen
        // Änderungen zusammen eingespeichert.
        guard let amount, amount > 0 else {
            errorMessage = String(localized: "Bitte einen gültigen positiven Betrag eingeben.")
            return false
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = String(localized: "Bitte einen Namen eingeben.")
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
        do {
            try await dependencies.recurringCommitmentRepository.upsert([updated])
            commitment = updated
            dependencies.changeTracker.markChanged()
            onChanged()
            return true
        } catch {
            errorMessage = String(localized: "Speichern fehlgeschlagen.")
            return false
        }
    }

    private func persistStatus(_ status: RecurringCommitment.Status) async {
        guard status != commitment.status else { return }
        isUpdatingStatus = true
        defer { isUpdatingStatus = false }

        let updated = RecurringCommitmentDraft.changingStatus(in: commitment, to: status)
        do {
            try await dependencies.recurringCommitmentRepository.upsert([updated])
            commitment = updated
            dependencies.changeTracker.markChanged()
            onChanged()
        } catch {
            errorMessage = String(localized: "Status konnte nicht gespeichert werden.")
        }
    }

    private func deleteCommitment() async {
        do {
            try await dependencies.recurringCommitmentRepository.delete(id: commitment.id)
            dependencies.changeTracker.markChanged()
            onChanged()
            dismiss()
        } catch {
            errorMessage = String(localized: "Löschen fehlgeschlagen.")
        }
    }

    private func assign(_ txn: Transaction) async {
        do {
            try await dependencies.recurringCommitmentRepository.addOccurrence(
                RecurringOccurrence(commitmentID: commitment.id, transactionID: txn.id)
            )
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            // WP5: Persistenz-Fehler werden nie geschluckt: der Nutzer
            // sieht, dass die Zuordnung nicht gespeichert wurde.
            errorMessage = String(localized: "Zuordnung konnte nicht gespeichert werden. Bitte erneut versuchen.")
        }
    }

    private func unassign(_ occurrence: RecurringOccurrence) async {
        do {
            try await dependencies.recurringCommitmentRepository.removeOccurrence(id: occurrence.id)
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            errorMessage = String(localized: "Zuordnung konnte nicht entfernt werden. Bitte erneut versuchen.")
        }
    }

    private func occurrence(for transactionID: UUID) async -> RecurringOccurrence? {
        (try? await dependencies.recurringCommitmentRepository.occurrences(commitmentID: commitment.id))?
            .first { $0.transactionID == transactionID }
    }
}

struct RecurringCommitmentDraft {
    var name: String
    var direction: RecurringCommitment.Direction
    var cadence: RecurringCommitment.Cadence
    var categoryID: UUID?
    var nextExpectedDate: Date?
    var amount: Decimal

    func newCommitment(currency: CurrencyCode, now: Date = Date()) -> RecurringCommitment {
        RecurringCommitment(
            name: name,
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
