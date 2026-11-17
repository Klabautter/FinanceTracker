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
    /// Nur, was dieser Typ nutzt (Roadmap 7.4, `DependencyCapabilities`).
    typealias Dependencies = any HasBaseCurrency & HasBudgetRepository & HasCategoryRepository & HasChangeTracker & HasRecurringCommitmentRepository

    let dependencies: Dependencies
    /// Existierendes Budget = Bearbeiten.
    var editing: Budget?
    let onSaved: () -> Void

    @State private var model: AddBudgetModel
    @State private var createsCategory = false
    @Environment(\.dismiss) private var dismiss

    init(dependencies: Dependencies, editing: Budget? = nil, onSaved: @escaping () -> Void) {
        self.dependencies = dependencies
        self.editing = editing
        self.onSaved = onSaved
        _model = State(initialValue: AddBudgetModel(dependencies: dependencies, editing: editing))
    }

    var body: some View {
        AdaptiveSheet(title: editing == nil ? String(localized: "Neues Budget") : String(localized: "Budget bearbeiten")) {
            Form {
                Section("Budget") {
                    TextField("Name (z. B. Lebensmittel)", text: $model.name)

                    // WP13: Kuratierter Picker statt roher SF-Symbol-Eingabe;
                    // er zeigt das gewählte Symbol selbst.
                    FinanceIconPicker(selection: $model.iconInput)

                    DecimalInputField(title: String(localized: "Monatliches Limit (z. B. 500)"), value: $model.amount)
                }

                Section("Kategorien") {
                    if model.loadState.isLoading || model.loadState == .idle {
                        Text("Lade Kategorien…").foregroundStyle(.secondary)
                    } else if model.leafCategories.isEmpty && model.loadState == .loaded {
                        Text("Noch keine Ausgabenkategorien. Lege unten eine an.").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                            ForEach(model.leafCategories) { category in
                                Button {
                                    model.toggleCategory(category.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: model.selectedCategoryIDs.contains(category.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(model.selectedCategoryIDs.contains(category.id) ? Color.accentColor : Color.secondary)
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
                                .accessibilityValue(model.selectedCategoryIDs.contains(category.id) ? Text("Ausgewählt") : Text("Nicht ausgewählt"))
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
                            model.adoptCreatedCategory(category)
                        },
                        suggestedName: model.name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : model.name
                    )
                }

                Section("Zeitraum") {
                    Picker("Zeitraum", selection: $model.useSalaryCycle) {
                        Text("Kalendermonat").tag(false)
                        Text("Gehalt zu Gehalt").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if model.useSalaryCycle {
                        if model.incomeCommitments.isEmpty {
                            Text("Keine Fix-Einnahmen vorhanden. Erfasse zuerst dein Gehalt unter „Wiederkehrend“.")
                                .font(.caption)
                                .foregroundStyle(AppPalette.critical)
                        } else {
                            Picker("Einkommen", selection: $model.salaryIncomeID) {
                                Text("Bitte auswählen").tag(UUID?.none)
                                ForEach(model.incomeCommitments) { commitment in
                                    Text(commitment.name).tag(UUID?.some(commitment.id))
                                }
                            }
                        }
                    }
                }

                Section {
                    Toggle("Rest in nächsten Monat übertragen", isOn: $model.rolloverAccumulate)
                }

                Section {
                    DecimalInputField(title: String(localized: "Zielbetrag (z. B. 1200)"), value: $model.targetAmount)
                    Toggle("Zieldatum setzen", isOn: $model.hasTargetDate)
                    if model.hasTargetDate {
                        DatePicker("Zieldatum", selection: $model.targetDate, displayedComponents: .date)
                    }
                } header: {
                    Text("Sparziel (optional)")
                } footer: {
                    Text("Sparziele nutzen Rücklagen-Budgets: Der verbleibende Rest zählt als Gespartes.")
                }

                if let errorMessage = model.loadState.failureMessage ?? model.actionError {
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
                    .disabled(!model.canSave || model.isSaving)
                }
            }
            .task { await model.load() }
        }
        #if os(macOS)
        .frame(width: 520, height: 620)
        #endif
    }

    private func save() async {
        guard await model.save() else { return }
        onSaved()
        dismiss()
    }
}

/// Formularzustand, Laden und Speichern eines Budgets (AGENTS.md Regeln 1
/// und 37).
@MainActor
@Observable
final class AddBudgetModel {
    /// Nur, was dieses Model nutzt (Roadmap 7.4, `DependencyCapabilities`).
    typealias Dependencies = any HasBaseCurrency & HasBudgetRepository & HasCategoryRepository & HasChangeTracker & HasRecurringCommitmentRepository

    var name = ""
    var iconInput = "chart.pie"
    /// WP4 (§28): Typed Decimal statt Display-String als Edit-State.
    var amount: Decimal?
    var selectedCategoryIDs: Set<UUID> = []
    var rolloverAccumulate = false
    var useSalaryCycle = false
    /// P2 Sparziel (optional, gleiche Währung wie das Budget).
    var targetAmount: Decimal?
    var hasTargetDate = false
    var targetDate = Date()
    var salaryIncomeID: UUID?
    private(set) var incomeCommitments: [RecurringCommitment] = []
    private(set) var leafCategories: [Category] = []
    private(set) var loadState: LoadState = .idle
    private(set) var actionError: String?
    private(set) var isSaving = false

    private let dependencies: Dependencies
    private let editing: Budget?

    init(dependencies: Dependencies, editing: Budget?) {
        self.dependencies = dependencies
        self.editing = editing
    }

    var selectedPeriodPolicy: BudgetPeriodPolicy? {
        BudgetPeriodFormSelection.policy(
            useSalaryCycle: useSalaryCycle,
            salaryIncomeID: salaryIncomeID,
            availableIncomeIDs: Set(incomeCommitments.map(\.id))
        )
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !selectedCategoryIDs.isEmpty
            && (amount ?? 0) > 0
            && selectedPeriodPolicy != nil
    }

    func toggleCategory(_ id: UUID) {
        if selectedCategoryIDs.contains(id) {
            selectedCategoryIDs.remove(id)
        } else {
            selectedCategoryIDs.insert(id)
        }
    }

    /// Eine aus dem Formular heraus angelegte Kategorie gleich auswählen.
    func adoptCreatedCategory(_ category: Category) {
        if !leafCategories.contains(where: { $0.id == category.id }) {
            leafCategories.append(category)
        }
        selectedCategoryIDs.insert(category.id)
    }

    func load() async {
        loadState = .loading
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
            loadState = .loaded
        } catch {
            loadState = .failed(String(localized: "Formulardaten konnten nicht geladen werden."))
        }
    }

    /// `true`, wenn das Budget gespeichert wurde.
    func save() async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        // §38: Ungültige/leere Eingabe → sichtbarer Fehler, Save blockiert,
        // Sheet bleibt offen. Kein stiller Fallback.
        guard let amount, amount > 0 else {
            actionError = String(localized: "Bitte einen gültigen positiven Betrag eingeben.")
            return false
        }
        guard !selectedCategoryIDs.isEmpty else {
            actionError = String(localized: "Bitte mindestens eine Kategorie auswählen.")
            return false
        }
        // Ein gewählter Gehaltszyklus ist ohne konkretes Einkommen ungültig.
        // Er darf niemals still als Kalendermonat gespeichert werden.
        guard let periodPolicy = selectedPeriodPolicy else {
            actionError = String(localized: "Bitte ein wiederkehrendes Einkommen für den Gehaltszyklus auswählen.")
            return false
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
        let budget = edit.applied(to: editing, baseCurrency: dependencies.baseCurrency)

        isSaving = true
        defer { isSaving = false }
        do {
            try await dependencies.budgetRepository.upsert([budget])
            dependencies.changeTracker.markChanged()
            actionError = nil
            return true
        } catch {
            actionError = String(localized: "Budget konnte nicht gespeichert werden.")
            return false
        }
    }
}
