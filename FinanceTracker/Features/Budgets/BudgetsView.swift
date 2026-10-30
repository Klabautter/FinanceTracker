import SwiftUI

struct BudgetsView: View {
    let dependencies: AppDependencies
    @Environment(\.isWorkspaceActive) private var isWorkspaceActive
    @State private var model: BudgetsModel
    @State private var budgetPendingDeletion: Budget?
    @State private var activeSheet: BudgetSheet?
    @State private var filter: BudgetOverviewFilter = .all
    @State private var searchText = ""
    @State private var selectedBudgetID: Budget.ID?
    @State private var showsInspector = false
    @State private var sortOrder = [KeyPathComparator(\BudgetOverviewRow.name)]
    @Environment(PrivacyPresentationState.self) private var privacyState

    private enum BudgetSheet: Identifiable {
        case add
        case edit(Budget)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let budget): "edit-\(budget.id.uuidString)"
            }
        }
    }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _model = State(initialValue: BudgetsModel(dependencies: dependencies))
    }

    var body: some View {
        Group {
            if model.isLoading, model.progresses.isEmpty {
                LoadingStateView()
            } else if model.progresses.isEmpty {
                emptyList
            } else {
                #if os(macOS)
                macWorkspace
                #else
                mobileList
                #endif
            }
        }
        .accessibilityIdentifier("screen-ready-budgets")
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let errorMessage = model.errorMessage {
                    InlineNotice(message: errorMessage, title: String(localized: "Budgets konnten nicht vollständig geladen werden"), tone: .critical)
                        .padding(.horizontal, AppLayout.pageHorizontalPadding)
                        .padding(.bottom, AppSpacing.s)
                }
                if let warning = model.salaryCycleFallbackWarning {
                    InlineNotice(message: warning, tone: .information)
                        .padding(.horizontal, AppLayout.pageHorizontalPadding)
                        .padding(.bottom, AppSpacing.s)
                        .accessibilityIdentifier("salary-cycle-fallback-warning")
                }
            }
        }
        .workspaceNavigationTitle(String(localized: "Budgets"))
        .workspaceHeading(
            String(localized: "Budgets"),
            subtitle: String(localized: "Deine Ausgaben planen und Grenzen im Blick behalten"),
            eyebrow: String(localized: "Planung")
        )
        .workspaceCanvas()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .workspaceToolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    activeSheet = .add
                } label: {
                    Label("Budget hinzufügen", systemImage: "plus")
                }
                .accessibilityLabel(Text("Budget hinzufügen"))
                .accessibilityIdentifier("Budget hinzufügen")
                .help("Neues Budget anlegen")
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
                .help(showsInspector ? String(localized: "Budgetdetails ausblenden") : String(localized: "Budgetdetails einblenden"))
            }
            #endif
            ToolbarItem(placement: .primaryAction) {

            #if !os(macOS)
                PrivacyToggleToolbarButton()
            #endif
            }
        }
        .task(id: model.dataRevision) { await model.load() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add:
                AddBudgetSheet(dependencies: dependencies) {
                    Task { await model.load() }
                }
            case .edit(let budget):
                AddBudgetSheet(dependencies: dependencies, editing: budget) {
                    Task { await model.load() }
                }
            }
        }
        .confirmationDialog(
            "Budget löschen?",
            isPresented: Binding(
                get: { budgetPendingDeletion != nil },
                set: { if !$0 { budgetPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                if let budget = budgetPendingDeletion {
                    if selectedBudgetID == budget.id {
                        selectedBudgetID = nil
                    }
                    Task { await model.delete(budget) }
                }
                budgetPendingDeletion = nil
            }
            Button("Abbrechen", role: .cancel) { budgetPendingDeletion = nil }
        } message: {
            Text("Das monatliche Limit für diese Kategorie wird entfernt.")
        }
        .onChange(of: model.progresses) { _, progresses in
            guard let selectedBudgetID,
                  !progresses.contains(where: { $0.id == selectedBudgetID }) else { return }
            self.selectedBudgetID = nil
        }
        .onDisappear {
            // Ein offener innerer Inspector darf beim Wechsel des äußeren
            // NavigationSplitView-Tabs nicht dessen Sidebar verdrängen.
            showsInspector = false
            selectedBudgetID = nil
        }
    }

    private var rows: [BudgetOverviewRow] {
        model.progresses.map { BudgetOverviewRow($0) }
    }

    private var visibleRows: [BudgetOverviewRow] {
        BudgetOverviewPresentation.filtered(rows, filter: filter, searchText: searchText)
            .sorted(using: sortOrder)
    }

    private var selectedProgress: BudgetProgress? {
        guard let selectedBudgetID else { return nil }
        return model.progresses.first { $0.id == selectedBudgetID }
    }

    #if os(macOS)
    private var macWorkspace: some View {
        DetailPaneLayout(
            isPresented: isWorkspaceActive && showsInspector,
            paneWidth: 320,
            paneAccessibilityLabel: String(localized: "Budgetdetails")
        ) {
            VStack(spacing: AppSpacing.m) {
                summaryBar
                filterBar
                    .padding(.horizontal, AppLayout.pageHorizontalPadding)
                budgetTable
                    // Leere Streifen unter wenigen Budgets sahen wie ein
                    // hängender Ladezustand aus.
                    .alternatingRowBackgrounds(.disabled)
                    .tableCard()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } pane: {
            budgetInspector
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("screen-ready-budgets")

    }

    @ViewBuilder
    private var budgetInspector: some View {
        if let progress = selectedProgress {
            BudgetDetailSheet(
                progress: progress,
                dependencies: dependencies,
                onEdit: { activeSheet = .edit(progress.budget) }
            )
            .id(progress)
        } else {
            ContentUnavailableView(
                "Kein Budget ausgewählt",
                systemImage: "sidebar.right",
                description: Text("Wähle ein Budget in der Tabelle aus, um Details zu sehen.")
            )
        }
    }

    private var budgetTable: some View {
        Table(visibleRows, selection: $selectedBudgetID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                budgetNameCell(row)
            }
            TableColumn("Fortschritt", value: \.statusSortOrder) { row in
                HStack(spacing: AppSpacing.s) {
                    FinanceProgressBar(fraction: row.progress.fraction, tone: row.status.tone, height: 6)
                    Text(BentoDashboardContent.percentText(spent: row.progress.spent, limit: row.progress.effectiveLimit))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(row.status.tone.foregroundColor)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .width(min: 140, ideal: 180)
            TableColumn("Verbrauch", value: \.spent) { row in
                amountCell(row.spent, currency: row.currency)
            }
            TableColumn("Rest / Überschreitung", value: \.signedRemaining) { row in
                VStack(alignment: .trailing, spacing: 1) {
                    amountCell(abs(row.signedRemaining), currency: row.currency)
                    (row.signedRemaining < 0 ? Text("überschritten") : Text("verbleibend"))
                        .font(.caption2)
                        .foregroundStyle(row.signedRemaining < 0 ? AppPalette.critical : Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            TableColumn("Prognose", value: \.projectionSortValue) { row in
                if let projection = row.projection {
                    amountCell(projection, currency: row.currency)
                } else {
                    Text("Noch nicht verfügbar")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            TableColumn("Zeitraum / Status", value: \.statusSortOrder) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.periodLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help(row.periodLabel)
                    StatusBadge(
                        title: row.status.title,
                        tone: row.status.tone,
                        systemImage: row.status.systemImage
                    )
                }
            }
        }
        // Im schmalen Fenster scrollt die Tabelle seitlich per Trackpad,
        // ohne dauerhaft sichtbaren Rollbalken.
        .scrollIndicators(.never, axes: .horizontal)
        .onChange(of: selectedBudgetID) { _, selection in
            if selection != nil {
                showsInspector = true
            }
        }
        .onDeleteCommand {
            guard let progress = selectedProgress else { return }
            budgetPendingDeletion = progress.budget
        }
        .accessibilityLabel("Budgettabelle")
    }

    private func budgetNameCell(_ row: BudgetOverviewRow) -> some View {
        HStack(spacing: AppSpacing.s) {
            IconTile(systemName: row.progress.budget.systemIconName, color: row.status.tone.foregroundColor, size: 24)
            Text(row.name)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .accessibilityIdentifier("budget-row-\(row.name)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Budget \(row.name)")
        .contextMenu {
            Button("Bearbeiten") {
                activeSheet = .edit(row.progress.budget)
            }
            Button("Löschen", role: .destructive) {
                budgetPendingDeletion = row.progress.budget
            }
        }
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
            Section {
                filterBar
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section("Budgets") {
                if visibleRows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(visibleRows) { row in
                        NavigationLink {
                            BudgetDetailSheet(
                                progress: row.progress,
                                dependencies: dependencies,
                                onEdit: { activeSheet = .edit(row.progress.budget) }
                            )
                        } label: {
                            BudgetProgressRow(row: row)
                        }
                        .accessibilityIdentifier("budget-row-\(row.name)")
                        .swipeActions(edge: .trailing) {
                            Button("Löschen", role: .destructive) {
                                budgetPendingDeletion = row.progress.budget
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
            title: String(localized: "Noch keine Budgets"),
            message: String(localized: "Lege Limits für Kategorien fest und verfolge Verbrauch, Restbetrag und Prognose direkt in der Übersicht."),
            systemImage: "chart.bar.fill"
        ) {
            Button("Erstes Budget hinzufügen") { activeSheet = .add }
                .buttonStyle(.borderedProminent)
        }
    }

    private var summaryBar: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            PlanningSummaryHero(
                title: String(localized: "Verbraucht in allen Budgets"),
                value: money(model.totalSpent),
                caption: String(localized: "von \(money(model.totalLimit)) geplantem Limit"),
                systemImage: "chart.pie.fill",
                progress: budgetUsageProgress,
                metrics: budgetSummaryMetrics,
                notice: budgetCurrencyNotice
            )
            // Kursstatus nur, wenn er Aufmerksamkeit braucht (veraltet,
            // fehlend); den Normalfall zeigen die Einstellungen.
            if let fxSnapshot = model.fxSnapshot, FXRateStatusPresentation.isWarning(fxSnapshot) {
                FXRateStatusView(snapshot: fxSnapshot, isLoading: model.fxIsLoading)
            }
        }
        .padding(.horizontal, AppLayout.pageHorizontalPadding)
        .accessibilityLabel("Budgetübersicht")
    }

    private var budgetSummaryMetrics: [PlanningSummaryMetric] {
        [
            PlanningSummaryMetric(label: String(localized: "Budgets"), value: "\(model.progresses.count)"),
            PlanningSummaryMetric(
                label: String(localized: "Gefährdet"),
                value: "\(rows.filter { $0.status == .atRisk }.count)",
                valueColor: rows.contains { $0.status == .atRisk } ? AppPalette.warning : .secondary
            ),
            PlanningSummaryMetric(
                label: String(localized: "Überschritten"),
                value: "\(rows.filter { $0.status == .over }.count)",
                valueColor: rows.contains { $0.status == .over } ? AppPalette.critical : .secondary
            )
        ]
    }

    private var filterBar: some View {
        FilterBar(searchText: $searchText, searchPrompt: String(localized: "Budgets suchen")) {
            Picker(selection: $filter) {
                ForEach(BudgetOverviewFilter.allCases) { filter in
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
            .accessibilityLabel("Budgets nach Status filtern")
        }
    }

    private var budgetUsageProgress: Double? {
        guard model.totalLimit > 0 else { return nil }
        return NSDecimalNumber(decimal: model.totalSpent / model.totalLimit).doubleValue
    }

    private var budgetCurrencyNotice: String? {
        var parts: [String] = []
        if !model.foreignBudgetCurrencies.isEmpty {
            let currencies = model.foreignBudgetCurrencies.map(\.rawValue).joined(separator: ", ")
            parts.append(String(localized: "\(currencies) wird getrennt ausgewiesen."))
        }
        // Ohne Referenzkurs ausgeschlossene Buchungen sichtbar machen,
        // sonst sieht das Budget grundlos gesund aus.
        if !model.unconvertibleCurrencies.isEmpty {
            let currencies = model.unconvertibleCurrencies.map(\.rawValue).joined(separator: ", ")
            parts.append(String(localized: "Buchungen in \(currencies) fehlen im Verbrauch (kein Referenzkurs)."))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func amountCell(_ amount: Decimal, currency: CurrencyCode) -> some View {
        Text(PrivacyAwareMoney.decimalString(amount, currency: currency, privacy: privacyState))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(PrivacyAwareMoney.accessibilityLabel(amount, currency: currency, privacy: privacyState))
    }

    private func money(_ amount: Decimal) -> String {
        PrivacyAwareMoney.decimalString(amount, currency: model.currency, privacy: privacyState)
    }
}

struct BudgetProgressRow: View {
    let row: BudgetOverviewRow
    @Environment(PrivacyPresentationState.self) private var privacyState

    private var savingsGoal: SavingsGoalProgress? {
        SavingsGoalCalculator().goalProgress(for: row.progress)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack {
                Label(row.name, systemImage: row.progress.budget.systemIconName)
                    .fontWeight(.medium)
                Spacer()
                Text(row.status.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(row.status.color)
            }
            HStack {
                Text(PrivacyAwareMoney.decimalString(row.spent, currency: row.currency, privacy: privacyState))
                Text("von")
                    .foregroundStyle(.secondary)
                Text(PrivacyAwareMoney.decimalString(row.progress.effectiveLimit, currency: row.currency, privacy: privacyState))
                Spacer()
                Text(row.periodLabel)
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            FinanceProgressBar(fraction: row.progress.fraction, tone: row.status.tone, height: 6)
            if let savingsGoal {
                HStack {
                    Image(systemName: "target")
                        .foregroundStyle(.secondary)
                    Text("Sparziel \(PrivacyAwareMoney.decimalString(savingsGoal.saved, currency: savingsGoal.currency, privacy: privacyState)) von \(PrivacyAwareMoney.decimalString(savingsGoal.target, currency: savingsGoal.currency, privacy: privacyState))")
                    Spacer()
                    Text("\(Int(savingsGoal.fraction * 100)) %")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Sparziel \(Int(savingsGoal.fraction * 100)) Prozent erreicht")
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(row.name), \(row.status.title), verbraucht \(PrivacyAwareMoney.accessibilityLabel(row.spent, currency: row.currency, privacy: privacyState))"
        )
    }
}

enum BudgetOverviewFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case onTrack
    case atRisk
    case over

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "Alle")
        case .onTrack: String(localized: "Im Plan")
        case .atRisk: String(localized: "Gefährdet")
        case .over: String(localized: "Überschritten")
        }
    }
}

enum BudgetOverviewStatus: Int, Comparable, Sendable {
    case onTrack
    case atRisk
    case over

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .onTrack: String(localized: "Im Plan")
        case .atRisk: String(localized: "Gefährdet")
        case .over: String(localized: "Überschritten")
        }
    }

    var systemImage: String {
        switch self {
        case .onTrack: "checkmark.circle.fill"
        case .atRisk: "exclamationmark.circle.fill"
        case .over: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .onTrack: AppPalette.positive
        case .atRisk: AppPalette.warning
        case .over: AppPalette.critical
        }
    }

    var tone: AppTone {
        switch self {
        case .onTrack: .positive
        case .atRisk: .warning
        case .over: .critical
        }
    }
}

struct BudgetOverviewRow: Identifiable, Sendable {
    let progress: BudgetProgress
    let projection: Decimal?
    let status: BudgetOverviewStatus

    var id: Budget.ID { progress.id }
    var name: String { progress.budget.name }
    var spent: Decimal { progress.spent }
    var currency: CurrencyCode { progress.currency }
    var signedRemaining: Decimal { progress.effectiveLimit - progress.spent }
    var projectionSortValue: Decimal { projection ?? -1 }
    var statusSortOrder: Int { status.rawValue }
    var periodLabel: String { BudgetOverviewPresentation.periodRange(progress.period) }

    init(_ progress: BudgetProgress, now: Date = Date(), calendar: Calendar = .current) {
        self.progress = progress
        let projection = BudgetOverviewPresentation.projection(for: progress, now: now, calendar: calendar)
        self.projection = projection
        if progress.isOverBudget {
            status = .over
        } else if let projection, projection > progress.effectiveLimit {
            status = .atRisk
        } else {
            status = .onTrack
        }
    }
}

enum BudgetOverviewPresentation {
    static func filtered(
        _ rows: [BudgetOverviewRow],
        filter: BudgetOverviewFilter,
        searchText: String
    ) -> [BudgetOverviewRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            let matchesStatus: Bool
            switch filter {
            case .all: matchesStatus = true
            case .onTrack: matchesStatus = row.status == .onTrack
            case .atRisk: matchesStatus = row.status == .atRisk
            case .over: matchesStatus = row.status == .over
            }
            return matchesStatus && (query.isEmpty || row.name.localizedCaseInsensitiveContains(query))
        }
    }

    static func periodType(for budget: Budget) -> String {
        switch budget.periodPolicy {
        case .calendarMonth: String(localized: "Kalendermonat")
        case .salaryCycle: String(localized: "Gehalt zu Gehalt")
        }
    }

    static func periodRange(_ period: DateInterval, calendar: Calendar = .current) -> String {
        let inclusiveEnd = max(period.start, calendar.date(byAdding: .day, value: -1, to: period.end) ?? period.end)
        // Kompakt und sprachgerecht („1.–31. Okt.", „Oct 1 – 31"); das Jahr
        // nur, wenn der Zeitraum nicht im laufenden Jahr liegt.
        let sameYear = calendar.isDate(period.start, equalTo: Date(), toGranularity: .year)
            && calendar.isDate(inclusiveEnd, equalTo: Date(), toGranularity: .year)
        let style = sameYear
            ? Date.IntervalFormatStyle().day().month(.abbreviated)
            : Date.IntervalFormatStyle().day().month(.abbreviated).year()
        return (period.start..<inclusiveEnd).formatted(style)
    }

    static func variance(for progress: BudgetProgress) -> Decimal {
        progress.isOverBudget
            ? progress.spent - progress.effectiveLimit
            : progress.remaining
    }

    static func projection(
        for progress: BudgetProgress,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Decimal? {
        guard progress.period.containsHalfOpen(now), progress.spent > 0 else { return nil }
        let counts = BudgetPeriodResolver().progress(in: progress.period, now: now, calendar: calendar)
        guard counts.elapsedDays > 0 else { return nil }
        return BudgetProgress.projectedMonthEndSpent(
            spent: progress.spent,
            elapsedDays: counts.elapsedDays,
            totalDaysInMonth: counts.totalDays
        )
    }
}

#if DEBUG
#Preview("Budgets") {
    NavigationStack {
        BudgetsView(dependencies: PreviewDependencies.dependencies())
    }
    .environment(PrivacyPresentationState())
}
#endif
