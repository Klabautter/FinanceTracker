import SwiftUI

enum BudgetPeriodFormSelection {
    static func policy(
        useSalaryCycle: Bool,
        salaryIncomeID: UUID?,
        availableIncomeIDs: Set<UUID>
    ) -> BudgetPeriodPolicy? {
        if useSalaryCycle {
            guard let salaryIncomeID, availableIncomeIDs.contains(salaryIncomeID) else { return nil }
            return .salaryCycle(recurringIncomeID: salaryIncomeID)
        }
        return .calendarMonth(startDay: 1)
    }
}

/// Budget 2.0 Form (Roadmap #109): Name, Icon, Betrag, Multi-Kategorien,
/// Rollover.
struct AddBudgetSheet: View {
    let dependencies: AppDependencies
    /// Existierendes Budget = Bearbeiten.
    var editing: Budget?
    let onSaved: () -> Void

    @State private var name = ""
    @State private var iconInput = "chart.pie"
    /// WP4 (§28): Typed Decimal statt Display-String als Edit-State.
    @State private var amount: Decimal?
    @State private var selectedCategoryIDs: Set<UUID> = []
    @State private var rolloverAccumulate = false
    @State private var useSalaryCycle = false
    /// P2 Sparziel (optional, gleiche Währung wie das Budget).
    @State private var targetAmount: Decimal?
    @State private var hasTargetDate = false
    @State private var targetDate = Date()
    @State private var incomeCommitments: [RecurringCommitment] = []
    @State private var salaryIncomeID: UUID?
    @State private var leafCategories: [Category] = []
    @State private var createsCategory = false
    @State private var editingBudget: Budget?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !selectedCategoryIDs.isEmpty
            && amount != nil
            && amount! > 0
            && selectedPeriodPolicy != nil
    }

    private var selectedPeriodPolicy: BudgetPeriodPolicy? {
        BudgetPeriodFormSelection.policy(
            useSalaryCycle: useSalaryCycle,
            salaryIncomeID: salaryIncomeID,
            availableIncomeIDs: Set(incomeCommitments.map(\.id))
        )
    }

    var body: some View {
        AdaptiveSheet(title: editing == nil ? String(localized: "Neues Budget") : String(localized: "Budget bearbeiten")) {
            Form {
                Section("Budget") {
                    TextField("Name (z. B. Lebensmittel)", text: $name)

                    // WP13: Kuratierter Picker statt roher SF-Symbol-Eingabe;
                    // er zeigt das gewählte Symbol selbst.
                    FinanceIconPicker(selection: $iconInput)

                    DecimalInputField(title: String(localized: "Monatliches Limit (z. B. 500)"), value: $amount)
                }

                Section("Kategorien") {
                    if leafCategories.isEmpty {
                        Text("Lade Kategorien…").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                            ForEach(leafCategories) { category in
                                Button {
                                    if selectedCategoryIDs.contains(category.id) {
                                        selectedCategoryIDs.remove(category.id)
                                    } else {
                                        selectedCategoryIDs.insert(category.id)
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: selectedCategoryIDs.contains(category.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedCategoryIDs.contains(category.id) ? Color.accentColor : Color.secondary)
                                        Text(category.name)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(category.name)
                                .accessibilityValue(selectedCategoryIDs.contains(category.id) ? Text("Ausgewählt") : Text("Nicht ausgewählt"))
                            }
                        }
                    }
                    Button {
                        createsCategory = true
                    } label: {
                        Label("Neue Kategorie …", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Neue Kategorie anlegen und für dieses Budget auswählen")
                }
                .sheet(isPresented: $createsCategory) {
                    CategoryEditorSheet(
                        dependencies: dependencies,
                        editing: nil,
                        onSaved: {},
                        onCreated: { category in
                            if !leafCategories.contains(where: { $0.id == category.id }) {
                                leafCategories.append(category)
                            }
                            selectedCategoryIDs.insert(category.id)
                        },
                        suggestedName: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
                    )
                }

                Section("Zeitraum") {
                    Picker("Zeitraum", selection: $useSalaryCycle) {
                        Text("Kalendermonat").tag(false)
                        Text("Gehalt zu Gehalt").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if useSalaryCycle {
                        if incomeCommitments.isEmpty {
                            Text("Keine Fix-Einnahmen vorhanden. Erfasse zuerst dein Gehalt unter „Wiederkehrend“.")
                                .font(.caption)
                                .foregroundStyle(AppPalette.critical)
                        } else {
                            Picker("Einkommen", selection: $salaryIncomeID) {
                                Text("Bitte auswählen").tag(UUID?.none)
                                ForEach(incomeCommitments) { commitment in
                                    Text(commitment.name).tag(UUID?.some(commitment.id))
                                }
                            }
                        }
                    }
                }

                Section {
                    Toggle("Rest in nächsten Monat übertragen", isOn: $rolloverAccumulate)
                } footer: {
                    Text("Rücklagen-Budgets (z. B. Autoversicherung) übertragen nicht ausgegebenes Geld in den Folgemonat.")
                }

                Section {
                    DecimalInputField(title: String(localized: "Zielbetrag (z. B. 1200)"), value: $targetAmount)
                    Toggle("Zieldatum setzen", isOn: $hasTargetDate)
                    if hasTargetDate {
                        DatePicker("Zieldatum", selection: $targetDate, displayedComponents: .date)
                    }
                } header: {
                    Text("Sparziel (optional)")
                } footer: {
                    Text("Sparziele nutzen Rücklagen-Budgets: Der verbleibende Rest zählt als Gespartes. Leeres Ziel = kein Sparziel.")
                }

                if let errorMessage {
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
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
            .task { await load() }
        }
        #if os(macOS)
        .frame(width: 520, height: 620)
        #endif
    }

    private func load() async {
        do {
            let all = try await dependencies.categoryRepository.categories()
            // WP12: Zentrale Leaf-only-Quelle (Parents = aggregation-only).
            // Einkünfte und Umbuchungen sind keine Ausgaben; ein Budget
            // darauf wäre wirkungslos. Bereits gewählte bleiben beim
            // Bearbeiten sichtbar.
            let nonSpendingIDs: Set<UUID> = [Category.income.id, Category.transfers.id]
            let alreadySelected = Set(editing?.categoryIDs ?? [])
            leafCategories = CategoryHierarchy().assignableCategories(in: all)
                .filter { !nonSpendingIDs.contains($0.id) || alreadySelected.contains($0.id) }
            incomeCommitments = try await dependencies.recurringCommitmentRepository.commitments()
                .filter { $0.direction == .income && $0.status == .active }

            if let editing {
                editingBudget = editing
                name = editing.name
                iconInput = editing.systemIconName
                amount = editing.amount
                selectedCategoryIDs = editing.categoryIDs
                rolloverAccumulate = editing.rolloverPolicy == .accumulate
                targetAmount = editing.targetAmount
                if let existingTargetDate = editing.targetDate {
                    hasTargetDate = true
                    targetDate = existingTargetDate
                }
                // WP4 (§30-31): Salary-Cycle-State aus periodPolicy
                // restaurieren, ohne Restore würde Save einen bestehenden
                // Gehaltszyklus still auf Kalendermonat zurückschreiben.
                switch editing.periodPolicy {
                case .calendarMonth:
                    useSalaryCycle = false
                    salaryIncomeID = nil
                case .salaryCycle(let recurringIncomeID):
                    useSalaryCycle = true
                    salaryIncomeID = recurringIncomeID
                }
            }
        } catch {
            errorMessage = String(localized: "Formulardaten konnten nicht geladen werden.")
        }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        // §38: Ungültige/leere Eingabe → sichtbarer Fehler, Save blockiert,
        // Sheet bleibt offen. Kein stiller Fallback.
        guard let amount, amount > 0 else {
            errorMessage = String(localized: "Bitte einen gültigen positiven Betrag eingeben.")
            return
        }
        guard !selectedCategoryIDs.isEmpty else {
            errorMessage = String(localized: "Bitte mindestens eine Kategorie auswählen.")
            return
        }

        // Ein gewählter Gehaltszyklus ist ohne konkretes Einkommen ungültig.
        // Er darf niemals still als Kalendermonat gespeichert werden.
        guard let periodPolicy = selectedPeriodPolicy else {
            errorMessage = String(localized: "Bitte ein wiederkehrendes Einkommen für den Gehaltszyklus auswählen.")
            return
        }

        let edit = BudgetFormEdit(
            name: trimmedName,
            systemIconName: iconInput,
            amount: amount,
            categoryIDs: selectedCategoryIDs,
            rolloverAccumulate: rolloverAccumulate,
            periodPolicy: periodPolicy,
            targetAmount: targetAmount,
            targetDate: hasTargetDate ? targetDate : nil
        )
        let budget = edit.applied(to: editingBudget, baseCurrency: dependencies.baseCurrency)

        do {
            try await dependencies.budgetRepository.upsert([budget])
            dependencies.changeTracker.markChanged()
            onSaved()
            dismiss()
        } catch {
            errorMessage = String(localized: "Budget konnte nicht gespeichert werden.")
        }
    }
}
