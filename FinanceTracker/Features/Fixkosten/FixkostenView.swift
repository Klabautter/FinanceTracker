import SwiftUI

struct FixkostenView: View {
    @Environment(\.isWorkspaceActive) private var isWorkspaceActive
    @State private var model: FixkostenModel
    @State private var commitmentPendingDeletion: RecurringCommitment?
    @State private var activeSheet: FixkostenSheet?
    private enum Workspace: String, CaseIterable, Identifiable {
        case upcoming = "Anstehend", all = "Zahlungspläne", suggestions = "Vorschläge"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .upcoming: String(localized: "Anstehend")
            case .all: String(localized: "Zahlungspläne")
            case .suggestions: String(localized: "Vorschläge")
            }
        }
    }
    @State private var workspace: Workspace = .upcoming
    @State private var filter: FixkostenOverviewFilter = .all
    @State private var searchText = ""
    @State private var selectedCommitmentID: RecurringCommitment.ID?
    @State private var showsInspector = false
    @State private var sortOrder = [KeyPathComparator(\FixkostenOverviewRow.name)]
    @Environment(PrivacyPresentationState.self) private var privacyState

    private enum FixkostenSheet: Identifiable {
        case create
        case edit(RecurringCommitment)

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let commitment): "edit-\(commitment.id.uuidString)"
            }
        }
    }

    init(dependencies: AppDependencies) {
        _model = State(initialValue: FixkostenModel(dependencies: dependencies))
    }

    var body: some View {
        Group {
            if model.isLoading, model.commitments.isEmpty, model.suggestions.isEmpty {
                LoadingStateView()
            } else if model.commitments.isEmpty, model.suggestions.isEmpty, model.hiddenSuggestions.isEmpty {
                emptyList
            } else {
                #if os(macOS)
                macWorkspace
                #else
                mobileList
                #endif
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = model.errorMessage {
                HStack(spacing: AppSpacing.m) {
                    InlineNotice(message: errorMessage, title: String(localized: "Zahlungspläne konnten nicht geladen werden"), tone: .critical)
                    Button("Erneut versuchen") { Task { await model.load() } }
                }
                .padding(.horizontal, AppLayout.pageHorizontalPadding)
                .padding(.bottom, AppSpacing.s)
            }
        }
        .accessibilityIdentifier("screen-ready-recurring")
        .workspaceNavigationTitle(String(localized: "Wiederkehrend"))
        .workspaceHeading(
            String(localized: "Wiederkehrend"),
            subtitle: String(localized: "Fixkosten, Abos und geplante Einnahmen"),
            eyebrow: String(localized: "Planung")
        )
        .workspaceCanvas()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: model.dataRevision) { await model.load() }
        #if os(macOS)
        .modifier(SuggestionUndoFocusedAction(model: model))
        #endif
        .workspaceToolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    activeSheet = .create
                } label: {
                    Label("Neuer Zahlungsplan", systemImage: "plus")
                }
                .accessibilityLabel("Zahlungsplan oder wiederkehrende Einnahme erfassen")
                .help("Neuen Zahlungsplan anlegen")
            }
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label(
                        showsInspector ? String(localized: "Details ausblenden") : String(localized: "Details einblenden"),
                        systemImage: "sidebar.right"
                    )
                }
                .help(showsInspector ? String(localized: "Details ausblenden") : String(localized: "Details einblenden"))
            }
            #endif
            ToolbarItem(placement: .primaryAction) {

            #if !os(macOS)
                PrivacyToggleToolbarButton()
            #endif
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .create:
                FixkostenCreateSheet(dependencies: model.dependencies) {
                    Task { await model.load() }
                }
            case .edit(let commitment):
                FixkostenDetailSheet(
                    commitment: commitment,
                    dependencies: model.dependencies,
                    onChanged: { Task { await model.load() } }
                )
            }
        }
        .confirmationDialog(
            "Zahlungsplan löschen?",
            isPresented: Binding(
                get: { commitmentPendingDeletion != nil },
                set: { if !$0 { commitmentPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                if let commitment = commitmentPendingDeletion {
                    if selectedCommitmentID == commitment.id {
                        selectedCommitmentID = nil
                    }
                    Task { await model.delete(commitment) }
                }
                commitmentPendingDeletion = nil
            }
            Button("Abbrechen", role: .cancel) {
                commitmentPendingDeletion = nil
            }
        } message: {
            Text("Die Zuordnungen zu Transaktionen werden ebenfalls entfernt.")
        }
        .onChange(of: model.commitments) { _, commitments in
            guard let selectedCommitmentID,
                  !commitments.contains(where: { $0.id == selectedCommitmentID }) else { return }
            self.selectedCommitmentID = nil
        }
        .onDisappear {
            // Der innere Inspector wird vor dem Wechsel des äußeren
            // NavigationSplitView-Tabs geschlossen. So bleibt die Sidebar
            // stabil und wird nicht auf Minimalbreite zusammengedrückt.
            showsInspector = false
            selectedCommitmentID = nil
        }
    }

    private var rows: [FixkostenOverviewRow] {
        model.commitments.map { commitment in
            FixkostenOverviewRow(
                commitment: commitment,
                resolution: model.currentPeriodResolutions[commitment.id],
                nextDate: model.nextExpectedDates[commitment.id] ?? commitment.nextExpectedDate
            )
        }
    }

    private var visibleRows: [FixkostenOverviewRow] {
        FixkostenPresentation.filtered(rows, filter: filter, searchText: searchText)
            .sorted(using: sortOrder)
    }

    private var selectedRow: FixkostenOverviewRow? {
        guard let selectedCommitmentID else { return nil }
        return rows.first { $0.id == selectedCommitmentID }
    }

    #if os(macOS)
    private var macWorkspace: some View {
        DetailPaneLayout(
            isPresented: isWorkspaceActive && showsInspector,
            paneWidth: 320,
            paneAccessibilityLabel: String(localized: "Zahlungsplandetails")
        ) {
            macWorkspaceContent
        } pane: {
            commitmentInspectorContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("screen-ready-recurring")
    }

    private var macWorkspaceContent: some View {
        VStack(spacing: AppSpacing.m) {
            summaryBar
            workspacePicker
            switch workspace {
            case .upcoming:
                ScrollView {
                    if model.upcomingWithin30Days.isEmpty {
                        EmptyStateView(
                            title: String(localized: "Keine offenen Termine"),
                            message: String(localized: "In den nächsten 30 Tagen sind keine offenen Einnahmen oder Ausgaben geplant. Alle Einträge findest du unter Zahlungspläne."),
                            systemImage: "calendar.badge.checkmark"
                        )
                        .frame(height: 280)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(model.upcomingWithin30Days.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { Divider().padding(.leading, 60) }
                                upcomingPaymentButton(entry)
                            }
                        }
                        .financeCard(padding: AppSpacing.s)
                        .padding(.horizontal, AppLayout.pageHorizontalPadding)
                        .padding(.bottom, AppSpacing.xl)
                    }
                }
            case .all:
                filterBar
                    .padding(.horizontal, AppLayout.pageHorizontalPadding)
                commitmentsTable
                    .tableCard()
            case .suggestions:
                ScrollView {
                    if model.suggestions.isEmpty {
                        EmptyStateView(
                            title: String(localized: "Keine Vorschläge"),
                            message: String(localized: "Neue wiederkehrende Muster erscheinen hier zur ausdrücklichen Bestätigung."),
                            systemImage: "sparkles"
                        )
                        .frame(height: 280)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, series in
                                if index > 0 { Divider() }
                                suggestionRow(series)
                            }
                        }
                        .financeCard(padding: AppSpacing.s)
                        .padding(.horizontal, AppLayout.pageHorizontalPadding)
                        .padding(.bottom, AppSpacing.l)
                    }
                    hiddenSuggestionsSection
                }
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("screen-ready-recurring")

    }

    @ViewBuilder
    private var commitmentInspectorContent: some View {
        if let row = selectedRow {
            commitmentInspector(row)
                .id(row.id)
        } else {
            ContentUnavailableView(
                "Kein Eintrag ausgewählt",
                systemImage: "sidebar.right",
                description: Text("Wähle eine Zeile aus, um Details zu sehen.")
            )
        }
    }

    private var commitmentsTable: some View {
        Table(visibleRows, selection: $selectedCommitmentID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                nameCell(row)
                    .accessibilityIdentifier("commitment-row-\(row.name)")
                    .contextMenu {
                        Button("Bearbeiten") { activeSheet = .edit(row.commitment) }
                        Button("Löschen", role: .destructive) {
                            commitmentPendingDeletion = row.commitment
                        }
                    }
            }
            TableColumn("Nächster Termin", value: \.dateSortValue) { row in
                Text(row.nextDate.map { AppDateFormatter.weekdayDay($0) } ?? String(localized: "Nicht geplant"))
                    .foregroundStyle(row.nextDate == nil ? .secondary : .primary)
            }
            TableColumn("Betrag", value: \.signedAmount) { row in
                amountCell(row)
            }
            TableColumn("Turnus", value: \.cadenceSortValue) { row in
                Text(row.commitment.cadence.displayName)
                    .foregroundStyle(.secondary)
            }
            TableColumn("Richtung", value: \.directionSortValue) { row in
                Text(row.commitment.direction.displayName)
                    .foregroundStyle(.secondary)
            }
            TableColumn("Status", value: \.statusSortValue) { row in
                statusBadge(row)
            }
        }
        .onChange(of: selectedCommitmentID) { _, selection in
            if selection != nil {
                showsInspector = true
            }
        }
        .onDeleteCommand {
            guard let row = selectedRow else { return }
            commitmentPendingDeletion = row.commitment
        }
        .accessibilityLabel("Tabelle der Fixkosten und wiederkehrenden Einnahmen")
    }

    private func nameCell(_ row: FixkostenOverviewRow) -> some View {
        HStack(spacing: AppSpacing.s) {
            IconTile(
                systemName: row.direction == .income ? "arrow.down.left" : "arrow.up.right",
                color: row.direction == .income ? AppPalette.positive : AppPalette.critical,
                size: 24
            )
            Text(row.name)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Zahlungsplan \(row.name)")
    }

    private func amountCell(_ row: FixkostenOverviewRow) -> some View {
        Text(PrivacyAwareMoney.decimalString(row.signedAmount, currency: row.currency, privacy: privacyState))
            .monospacedDigit()
            .foregroundStyle(row.direction == .income ? AppPalette.positive : Color.primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(
                PrivacyAwareMoney.accessibilityLabel(row.signedAmount, currency: row.currency, privacy: privacyState)
            )
    }

    private func statusBadge(_ row: FixkostenOverviewRow) -> some View {
        StatusBadge(
            title: row.statusTitle,
            tone: row.status.tone,
            systemImage: row.status.systemImage
        )
    }

    private func commitmentInspector(_ row: FixkostenOverviewRow) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    Label(
                        row.name,
                        systemImage: row.direction == .income ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
                    )
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(row.direction == .income ? AppPalette.positive : .primary)
                    Text(PrivacyAwareMoney.decimalString(row.signedAmount, currency: row.currency, privacy: privacyState))
                        .font(.title2.monospacedDigit())
                    Label(row.statusTitle, systemImage: row.status.systemImage)
                        .foregroundStyle(row.status.color)
                }
                .padding(.vertical, AppSpacing.xs)
            }
            Section("Planung") {
                LabeledContent("Nächster Termin", value: row.nextDate.map { AppDateFormatter.weekdayDay($0) } ?? String(localized: "Nicht geplant"))
                if row.nextDate == nil && row.commitment.status == .active {
                    Text("Ohne nächsten Termin erscheint diese Zahlung nicht in der Vorschau.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Termin festlegen") { activeSheet = .edit(row.commitment) }
                        .accessibilityIdentifier("recurring-set-date")
                }
                LabeledContent("Turnus", value: row.commitment.cadence.displayName)
                LabeledContent("Richtung", value: row.commitment.direction.displayName)
                LabeledContent("Betragsart", value: row.commitment.amountPolicy.displayName)
                LabeledContent("Kategorie") {
                    if let category = model.category(for: row.commitment) {
                        Label(category.name, systemImage: category.systemIconName)
                            .foregroundStyle(category.colorToken.color)
                    } else {
                        Text(Category.uncategorizedDisplayName).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button("Bearbeiten") {
                    activeSheet = .edit(row.commitment)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                Button("Löschen", role: .destructive) {
                    commitmentPendingDeletion = row.commitment
                }
            }
        }
        .financeFormStyle()
        .accessibilityLabel("Details zu \(row.name)")
        .accessibilityIdentifier("recurring-inspector-\(row.name)")
    }
    #endif

    #if os(iOS)
    private var mobileList: some View {
        List {
            Section {
                summaryBar
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if !model.upcomingWithin30Days.isEmpty {
                Section("Als Nächstes") {
                    upcomingPayments
                        .listRowInsets(EdgeInsets())
                }
            }
            if !model.suggestions.isEmpty {
                Section {
                    suggestionBanner
                        .listRowInsets(EdgeInsets())
                }
            }
            Section {
                filterBar
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section("Zahlungspläne und Einnahmen") {
                if visibleRows.isEmpty {
                    Text("Keine Einträge für diesen Filter.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleRows) { row in
                        Button {
                            activeSheet = .edit(row.commitment)
                        } label: {
                            commitmentRow(row)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("commitment-row-\(row.name)")
                        .swipeActions(edge: .trailing) {
                            Button("Löschen", role: .destructive) {
                                commitmentPendingDeletion = row.commitment
                            }
                        }
                    }
                }
            }
        }
        .refreshable { await model.load() }
    }
    #endif

    private var emptyList: some View {
        EmptyStateView(
            title: String(localized: "Noch keine Zahlungspläne"),
            message: String(localized: "Erfasse wiederkehrende Beträge wie Miete, Abos oder Gehalt, damit Termine und Zahlstatus an einem Ort sichtbar sind."),
            systemImage: "calendar.badge.plus"
        ) {
            Button("Ersten Eintrag hinzufügen") { activeSheet = .create }
                .buttonStyle(.borderedProminent)
        }
    }

    private var summaryBar: some View {
        PlanningSummaryHero(
            title: String(localized: "Pro Monat"),
            value: formattedSummaryAmount(model.monthlyTotal),
            caption: String(localized: "wiederkehrende Ausgaben im Monatsdurchschnitt"),
            systemImage: "calendar.badge.clock",
            metrics: recurringSummaryMetrics,
            notice: recurringCurrencyNotice
        )
        .padding(.horizontal, AppLayout.pageHorizontalPadding)
        .accessibilityLabel("Monatlicher Überblick")
    }

    /// Zwei Kennzahlen, die den Hauptwert ergänzen statt wiederholen:
    /// „Diese Periode" entsprach meist dem Monatswert, „Ø Einnahmen" gehört
    /// nicht in einen Fixkosten-Kopf.
    private var recurringSummaryMetrics: [PlanningSummaryMetric] {
        [
            PlanningSummaryMetric(
                label: String(localized: "Noch offen"),
                value: formattedSummaryAmount(model.openTotal),
                valueColor: model.openTotal > 0 ? AppPalette.warning : .secondary
            ),
            PlanningSummaryMetric(
                label: String(localized: "Nächster Termin"),
                value: (model.upcomingWithin30Days.first { !$0.isOverdue }).map { AppDateFormatter.weekdayDay($0.scheduledDate) } ?? "–"
            )
        ]
    }

    private var upcomingPayments: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Als Nächstes")
                    .font(.headline)
                Spacer()
                Text("kommende 30 Tage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(model.upcomingWithin30Days.prefix(3).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider()
                                .frame(height: 42)
                                .padding(.horizontal, AppSpacing.m)
                        }
                        upcomingPaymentButton(entry)
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    ForEach(model.upcomingWithin30Days.prefix(3)) { entry in
                        upcomingPaymentButton(entry)
                    }
                }
            }
        }
        .padding(.horizontal, AppSpacing.l)
        .padding(.vertical, AppSpacing.m)
        .accessibilityElement(children: .contain)
    }

    private func upcomingPaymentButton(_ entry: FixkostenModel.UpcomingEntry) -> some View {
        Button {
            openUpcoming(entry)
        } label: {
            HStack(spacing: AppSpacing.m) {
                DateBadge(date: entry.scheduledDate)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.commitment.name)
                        .font(.callout.weight(.medium))
                    Text(upcomingSubtitle(entry))
                        .font(.caption)
                        .foregroundStyle(entry.isOverdue ? AnyShapeStyle(AppPalette.warning) : AnyShapeStyle(.secondary))
                }
                Spacer()
                Text(PrivacyAwareMoney.signedTotal(
                    entry.commitment.expectedAmount,
                    kind: entry.commitment.direction == .expense ? .expense : .income,
                    currency: entry.commitment.currency, privacy: privacyState
                ))
                .font(AppTypography.amount.monospacedDigit())
                .foregroundStyle(entry.commitment.direction == .income ? AppPalette.positive : Color.primary)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHighlightButtonStyle())
        .accessibilityLabel(upcomingAccessibilityLabel(entry))
    }

    private func upcomingDirectionText(_ entry: FixkostenModel.UpcomingEntry) -> String {
        entry.commitment.direction == .income ? String(localized: "Einnahme") : String(localized: "Ausgabe")
    }

    private func upcomingSubtitle(_ entry: FixkostenModel.UpcomingEntry) -> String {
        let date = AppDateFormatter.weekdayDay(entry.scheduledDate)
        let cadence = entry.commitment.cadence.displayName
        let direction = upcomingDirectionText(entry)
        return entry.isOverdue
            ? String(localized: "Überfällig seit \(date) · \(cadence) · \(direction)")
            : "\(date) · \(cadence) · \(direction)"
    }

    private func upcomingAccessibilityLabel(_ entry: FixkostenModel.UpcomingEntry) -> String {
        let name = entry.commitment.name
        let direction = upcomingDirectionText(entry)
        let date = AppDateFormatter.weekdayDay(entry.scheduledDate)
        let amount = PrivacyAwareMoney.accessibilityLabel(
            entry.commitment.expectedAmount,
            currency: entry.commitment.currency,
            privacy: privacyState
        )
        return entry.isOverdue
            ? String(localized: "\(name), \(direction), überfällig seit \(date), \(amount)")
            : String(localized: "\(name), \(direction), fällig \(date), \(amount)")
    }

    private func openUpcoming(_ entry: FixkostenModel.UpcomingEntry) {
        #if os(macOS)
        selectedCommitmentID = entry.commitment.id
        showsInspector = true
        #else
        activeSheet = .edit(entry.commitment)
        #endif
    }

    private var filterBar: some View {
        FilterBar(searchText: $searchText, searchPrompt: String(localized: "Einträge suchen")) {
            Picker(selection: $filter) {
                ForEach(FixkostenOverviewFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            } label: {
                Label("Status: \(filter.title)", systemImage: "line.3.horizontal.decrease")
            }
            #if os(macOS)
            .pickerStyle(.segmented)
            .labelsHidden()
            #else
            .pickerStyle(.menu)
            #endif
            .accessibilityLabel("Zahlungspläne filtern")
        }
    }

    private var workspacePicker: some View {
        Picker("Ansicht", selection: $workspace) {
            ForEach(Workspace.allCases) { item in Text(item.title).tag(item) }
        }
        .pickerStyle(.segmented)
            .labelsHidden()
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.horizontal, AppLayout.pageHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("recurring-workspace")
    }

    @ViewBuilder
    private var suggestionBanner: some View {
        if let series = model.suggestions.first { suggestionRow(series) }
    }

    /// Ausgeblendete Vorschläge bleiben erreichbar: Wer „Nicht anzeigen“
    /// versehentlich geklickt hat, holt sie hier zurück.
    @ViewBuilder
    private var hiddenSuggestionsSection: some View {
        if !model.hiddenSuggestions.isEmpty {
            DisclosureGroup("Ausgeblendete Vorschläge (\(model.hiddenSuggestions.count))") {
                VStack(spacing: 0) {
                    ForEach(Array(model.hiddenSuggestions.enumerated()), id: \.element.id) { index, series in
                        if index > 0 { Divider() }
                        HStack(spacing: AppSpacing.s) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(series.displayName)
                                    .lineLimit(1)
                                Text("\(FixkostenPresentation.suggestionSubtitle(cadence: series.cadence.displayName, occurrenceCount: series.occurrences.count)) · \(model.accountLabel(for: series))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            MoneyText(money: Money(amount: series.medianAmount, currency: series.currency))
                                .foregroundStyle(.secondary)
                            Button("Wieder anzeigen") {
                                Task { await model.restoreSuggestion(series) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Vorschlag für \(series.displayName) wieder anzeigen")
                        }
                        .padding(.horizontal, AppSpacing.m)
                        .padding(.vertical, AppSpacing.s)
                    }
                }
                .financeCard(padding: AppSpacing.s)
                .padding(.top, AppSpacing.s)
            }
            .padding(.horizontal, AppLayout.pageHorizontalPadding)
            .padding(.bottom, AppSpacing.xl)
        }
    }

    private func suggestionRow(_ series: RecurringSeries) -> some View {
            HStack(spacing: AppSpacing.s) {
                IconTile(systemName: "sparkles", color: AppPalette.brand, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(series.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text("\(FixkostenPresentation.suggestionSubtitle(cadence: series.cadence.displayName, occurrenceCount: series.occurrences.count)) · \(model.accountLabel(for: series))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                MoneyText(money: Money(amount: series.medianAmount, currency: series.currency))
                Button("Bestätigen") {
                    Task { await model.confirmSuggestion(series, categoryID: series.categoryID) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Nicht anzeigen") {
                    Task { await model.dismissSuggestion(series) }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, AppSpacing.m)
            .padding(.vertical, AppSpacing.s)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Vorschlag für \(series.displayName)")
    }

    private func commitmentRow(_ row: FixkostenOverviewRow) -> some View {
        HStack(spacing: AppSpacing.s) {
            Image(systemName: row.status.systemImage)
                .foregroundStyle(row.status.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .fontWeight(.medium)
                Text("\(row.commitment.cadence.displayName) · \(row.nextDate.map { AppDateFormatter.day($0) } ?? String(localized: "kein Termin")) · \(row.statusTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.orphanedCommitmentIDs.contains(row.id) {
                    Label("Konto nicht mehr vorhanden: Zahlungen werden nicht erkannt", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(AppPalette.warning)
                }
            }
            Spacer()
            Text(PrivacyAwareMoney.decimalString(row.signedAmount, currency: row.currency, privacy: privacyState))
                .font(.callout.monospacedDigit())
                .foregroundStyle(row.direction == .income ? AppPalette.positive : .primary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(commitmentAccessibilityLabel(row))
    }

    private func commitmentAccessibilityLabel(_ row: FixkostenOverviewRow) -> String {
        let amount = PrivacyAwareMoney.accessibilityLabel(row.signedAmount, currency: row.currency, privacy: privacyState)
        let cadence = row.commitment.cadence.displayName
        let status = row.statusTitle
        return model.orphanedCommitmentIDs.contains(row.id)
            ? String(localized: "\(row.name), \(amount), \(cadence), \(status), Konto nicht mehr vorhanden")
            : "\(row.name), \(amount), \(cadence), \(status)"
    }

    private func formattedSummaryAmount(_ amount: Decimal) -> String {
        PrivacyAwareMoney.decimalString(
            amount,
            currency: model.dependencies.baseCurrency,
            privacy: privacyState
        )
    }

    private var recurringCurrencyNotice: String? {
        guard !model.summary.foreignCurrencies.isEmpty else { return nil }
        let currencies = model.summary.foreignCurrencies.map(\.rawValue).joined(separator: ", ")
        return String(localized: "Fremdwährungen (\(currencies)) werden getrennt ausgewiesen.")
    }
}

enum FixkostenOverviewFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case open
    case paid
    case paused
    case income

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "Alle")
        case .open: String(localized: "Offen")
        case .paid: String(localized: "Bezahlt")
        case .paused: String(localized: "Pausiert")
        case .income: String(localized: "Einnahmen")
        }
    }
}

enum FixkostenOverviewStatus: Int, Comparable, Sendable {
    case open
    case partial
    case paid
    case paused

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var systemImage: String {
        switch self {
        case .open: "calendar.circle"
        case .partial: "circle.lefthalf.filled"
        case .paid: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .open: AppPalette.warning
        case .partial: AppPalette.warning
        case .paid: AppPalette.positive
        case .paused: .secondary
        }
    }

    var tone: AppTone {
        switch self {
        case .open, .partial: .warning
        case .paid: .positive
        case .paused: .neutral
        }
    }
}

struct FixkostenOverviewRow: Identifiable, Sendable {
    let commitment: RecurringCommitment
    let nextDate: Date?
    let status: FixkostenOverviewStatus

    var id: RecurringCommitment.ID { commitment.id }
    var name: String { commitment.name }
    var direction: RecurringCommitment.Direction { commitment.direction }
    var currency: CurrencyCode { commitment.currency }
    var signedAmount: Decimal { direction == .expense ? -commitment.expectedAmount : commitment.expectedAmount }
    var dateSortValue: Date { nextDate ?? .distantFuture }
    var cadenceSortValue: String { commitment.cadence.displayName }
    var directionSortValue: String { commitment.direction.displayName }
    var statusSortValue: Int { status.rawValue }
    var statusTitle: String {
        switch status {
        case .open: direction == .income ? String(localized: "Erwartet") : String(localized: "Offen")
        case .partial: String(localized: "Teilweise bezahlt")
        case .paid: direction == .income ? String(localized: "Eingegangen") : String(localized: "Bezahlt")
        case .paused: String(localized: "Pausiert")
        }
    }

    init(
        commitment: RecurringCommitment,
        resolution: RecurringOccurrenceResolution?,
        nextDate: Date?
    ) {
        self.commitment = commitment
        self.nextDate = nextDate
        if commitment.status == .paused {
            status = .paused
        } else if let resolution,
                  !resolution.scheduled.isEmpty,
                  resolution.scheduled.allSatisfy(\.isPaid),
                  resolution.openAmount == 0 {
            status = .paid
        } else if let resolution,
                  resolution.paidCount > 0,
                  resolution.openAmount > 0 {
            status = .partial
        } else {
            status = .open
        }
    }

    /// Kompatibilität für bestehende reine Presentation-Tests. Die echte
    /// App leitet den Status occurrence-basiert über `resolution` ab.
    init(commitment: RecurringCommitment, isPaid: Bool, nextDate: Date?) {
        self.commitment = commitment
        self.nextDate = nextDate
        if commitment.status == .paused {
            status = .paused
        } else {
            status = isPaid ? .paid : .open
        }
    }
}

/// Manuelle Erfassung (#112): Name, Richtung, Turnus, Betrag, Kategorie.
struct FixkostenCreateSheet: View {
    let dependencies: AppDependencies
    let onSaved: () -> Void

    @State private var name = ""
    @State private var direction: RecurringCommitment.Direction = .expense
    @State private var cadence: RecurringCommitment.Cadence = .monthly
    @State private var amount: Decimal?
    @State private var categoryID: UUID?
    @State private var nextExpectedDate = Date()
    @State private var leafCategories: [Category] = []
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && amount != nil
            && amount! > 0
    }

    var body: some View {
        AdaptiveSheet(title: FixkostenPresentation.creationTitle(for: direction)) {
            Form {
                Section {
                    TextField("Name (z. B. Miete, Spotify)", text: $name)
                    DecimalInputField(title: String(localized: "Betrag (z. B. 10,99)"), value: $amount)
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
                    DatePicker(
                        selection: $nextExpectedDate,
                        displayedComponents: .date
                    ) {
                        direction == .expense
                            ? Text("Start-/nächstes Fälligkeitsdatum")
                            : Text("Start-/nächstes Eingangsdatum")
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
            .task { await loadCategories() }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 540, minHeight: 390, idealHeight: 450, maxHeight: 560)
        #endif
    }

    private func loadCategories() async {
        do {
            let all = try await dependencies.categoryRepository.categories()
            leafCategories = all
                .filter { category in !all.contains { $0.parentID == category.id } }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = String(localized: "Kategorien konnten nicht geladen werden.")
        }
    }

    private func save() async {
        guard let amount, amount > 0 else {
            errorMessage = String(localized: "Bitte einen gültigen positiven Betrag eingeben.")
            return
        }
        let draft = RecurringCommitmentDraft(
            name: name.trimmingCharacters(in: .whitespaces),
            direction: direction,
            cadence: cadence,
            categoryID: categoryID,
            nextExpectedDate: nextExpectedDate,
            amount: amount
        )
        let commitment = draft.newCommitment(currency: dependencies.baseCurrency)
        do {
            try await dependencies.recurringCommitmentRepository.upsert([commitment])
            dependencies.changeTracker.markChanged()
            onSaved()
            dismiss()
        } catch {
            errorMessage = String(localized: "Speichern fehlgeschlagen.")
        }
    }
}

enum FixkostenPresentation {
    static func filtered(
        _ rows: [FixkostenOverviewRow],
        filter: FixkostenOverviewFilter,
        searchText: String
    ) -> [FixkostenOverviewRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .open:
                matchesFilter = row.direction == .expense && (row.status == .open || row.status == .partial)
            case .paid: matchesFilter = row.status == .paid
            case .paused: matchesFilter = row.status == .paused
            case .income: matchesFilter = row.direction == .income
            }
            return matchesFilter && (query.isEmpty || row.name.localizedCaseInsensitiveContains(query))
        }
    }

    static func creationTitle(for direction: RecurringCommitment.Direction) -> String {
        switch direction {
        case .expense: String(localized: "Neuer Zahlungsplan")
        case .income: String(localized: "Neue wiederkehrende Einnahme")
        }
    }

    static func suggestionSubtitle(cadence: String, occurrenceCount: Int) -> String {
        String(localized: "\(cadence) · \(occurrenceCount)× erkannt")
    }
}
