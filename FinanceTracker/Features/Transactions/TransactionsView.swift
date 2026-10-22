import SwiftUI

struct TransactionsView: View {
    let dependencies: AppDependencies
    /// WP24: Ausstehende Palette-Route (Transaktion/Tag).
    var pendingRoute: Binding<PaletteRoute?>
    var reviewCount: Int?

    init(dependencies: AppDependencies, pendingRoute: Binding<PaletteRoute?>, reviewCount: Int? = nil) {
        self.dependencies = dependencies
        self.pendingRoute = pendingRoute
        self.reviewCount = reviewCount
    }

    var body: some View {
        #if os(macOS)
        MacTransactionsContent(dependencies: dependencies, pendingRoute: pendingRoute, reviewCount: reviewCount)
        #else
        MobileTransactionsContent(dependencies: dependencies, pendingRoute: pendingRoute, reviewCount: reviewCount)
        #endif
    }
}

#if os(macOS)

private struct MacTransactionsContent: View {
    @Environment(\.isWorkspaceActive) private var isWorkspaceActive
    @State private var model: TransactionsModel
    @State private var selection: Set<Transaction.ID> = []
    @State private var inspector = TransactionInspectorState()
    @State private var activeSheet: TransactionSheet?
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isTableFocused: Bool
    let reviewCount: Int?

    private enum TransactionSheet: String, Identifiable {
        case addTransaction
        case addDataSource
        case reviewQueue
        var id: String { rawValue }
    }

    /// WP24: Ausstehende Palette-Route (Transaktion/Tag), konsumiert beim
    /// ersten Aufbau der Ansicht.
    var pendingRoute: Binding<PaletteRoute?>

    init(dependencies: AppDependencies, pendingRoute: Binding<PaletteRoute?>, reviewCount: Int?) {
        _model = State(initialValue: TransactionsModel(dependencies: dependencies))
        self.pendingRoute = pendingRoute
        self.reviewCount = reviewCount
    }

    var body: some View {
        @Bindable var model = model

        // Detailbereich als fester HStack wie bei Budgets/Wiederkehrend: Der
        // native `.inspector`-Split-Container nahm die ideale Höhe seines
        // Inhalts an (weit über Fensterhöhe) und schob Lade-/Leerzustände aus
        // dem sichtbaren Bereich.
        DetailPaneLayout(
            isPresented: isWorkspaceActive && inspector.isPresented,
            paneWidth: 340,
            paneAccessibilityLabel: String(localized: "Transaktionsdetails")
        ) {
            VStack(spacing: 0) {
                header
                // Mit offenem Detailbereich steht die Rückfrage dort, direkt
                // bei der geänderten Kategorie.
                if let offer = model.merchantCategoryOffer, !(isWorkspaceActive && inspector.isPresented) {
                    MerchantCategoryOfferView(
                        offer: offer,
                        onApply: { Task { await model.applyMerchantCategoryOffer() } },
                        onDismiss: { model.dismissMerchantCategoryOffer() }
                    )
                    .padding(.horizontal, AppLayout.pageHorizontalPadding)
                    .padding(.bottom, AppSpacing.s)
                }
                Group {
                    if let errorMessage = model.errorMessage, model.transactions.isEmpty {
                        ErrorStateView(message: errorMessage) {
                            Task { await model.refresh() }
                        }
                    } else if model.transactions.isEmpty {
                        if model.isLoading {
                            LoadingStateView()
                        } else {
                            transactionEmptyState
                        }
                    } else {
                        // MacUX-Audit: Tabelle in eigenem View-Kontext, Inspector-
                        // Toggle, Toolbar- und Suche-Zustände re-evaluieren nicht
                        // mehr die Table-Observation-Kette (Inspector-Lag).
                        // P0 (#31): Doppelklick öffnet den Inspector explizit,
                        // eine Auswahl allein öffnet ihn nicht mehr.
                        MacTransactionsTable(model: model, selection: $selection)
                            .tableCard()
                            .focused($isTableFocused)
                            .accessibilityIdentifier("screen-ready-transactions")
                            .contextMenu(forSelectionType: Transaction.ID.self) { _ in
                                EmptyView()
                            } primaryAction: { ids in
                                guard !ids.isEmpty else { return }
                                selection = ids
                                isSearchFocused = false
                                inspector.openExplicitly()
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } pane: {
            TransactionInspectorPane(model: model, selection: selection, isPresented: inspector.isPresented)
        }
        .background(AppPalette.canvas)
        .workspaceToolbar { macToolbar }
        .modifier(TransactionFocusedActions(
            isSearchFocused: $isSearchFocused,
            quickActions: transactionQuickActions,
            undoActions: transactionUndoActions,
            model: model
        ))
        .manualTransactionPresenter(model)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addTransaction:
                AddTransactionSheet(dependencies: model.dependencies) {
                    Task { await model.refresh() }
                }
            case .addDataSource:
                AddDataSourceView(dependencies: model.dependencies) {
                    activeSheet = nil
                }
                .frame(width: 520, height: 620)
            case .reviewQueue:
                ReviewQueueView(dependencies: model.dependencies, showsDismissButton: true)
                    .frame(width: 720, height: 540)
            }
        }
        .onChange(of: isWorkspaceActive) { _, active in
            if !active {
                isSearchFocused = false
                isTableFocused = false
            }
        }
        .onChange(of: selection) { _, _ in
            isSearchFocused = false
            isTableFocused = true
            // P0 (#31): Eine (neue) Auswahl öffnet den Inspector NICHT
            // automatisch, er öffnet erst bei Doppelklick, Info-Button
            // oder ⌘I. Das Leeren der Auswahl schließt ihn nicht
            // zwangsläufig (State-Regel: TransactionInspectorState).
            inspector.selectionDidChange()
        }
        .onChange(of: model.searchText) { _, _ in
            model.searchTextChanged()
        }
        .workspaceNavigationTitle(String(localized: "Transaktionen"))
        .task(id: model.dataRevision) {
            // MacUX-Perf: Nur EXTERNE Änderungen (Import, andere Screens)
            // lösen einen Re-Fetch aus, eigene Edits sind in-memory
            // aktuell (Revisionen entsprechen sich) und würden sonst pro
            // Klick die erste DB-Seite neu laden und die Tabelle zurück-
            // setzen. Externe Stürme coalescen in 250 ms; Deep-Links
            // werden weiterhin konsumiert.
            if !model.hasLoadedData || model.dataRevision != model.lastLocalRevision {
                if model.hasLoadedData {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                }
                await model.refresh()
            }
            consumePendingRoute()
        }
        .onChange(of: model.tableSortOrder) { _, _ in
            // WP21: Spaltenkopf-Klick → globale Store-Sortierung.
            model.resortInPlace()
        }
        .onChange(of: model.filterCategoryID) { _, _ in
            model.filterChanged()
        }
        .onChange(of: model.filterTagIDs) { _, _ in
            Task { await model.loadMoreForTagFilter() }
        }
        .onChange(of: pendingRoute.wrappedValue) { _, route in
            // WP24/MacUX-Perf: Deep-Link, während der Screen bereits
            // sichtbar ist (kein Revisions-Bump → kein `.task`-Re-Fire).
            guard route != nil else { return }
            consumePendingRoute()
        }
    }

    private var transactionSearchField: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Händler oder Beschreibung", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .accessibilityIdentifier("transactions-search")
                #if os(macOS)
                // macOS-Konvention: Esc leert das Suchfeld bzw. verlässt es.
                .onExitCommand {
                    if model.searchText.isEmpty {
                        isSearchFocused = false
                    } else {
                        model.searchText = ""
                    }
                }
                #endif
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Suche leeren")
                .help("Suche leeren")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(AppPalette.sunken, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .frame(width: 280)
    }

    /// Kopfbereich als normaler Stack statt `safeAreaInset`: In Kombination mit
    /// `.inspector` wuchs der Split-Container sonst über die Fensterhöhe hinaus
    /// und schob Lade-/Leerzustand aus dem sichtbaren Bereich.
    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                String(localized: "Transaktionen"),
                subtitle: String(localized: "Alle Kontobewegungen an einem Ort"),
                eyebrow: String(localized: "Alltag")
            ) {
                Button { activeSheet = .reviewQueue } label: {
                    HStack(spacing: 6) {
                        if (reviewCount ?? 0) > 0 {
                            Circle().fill(AppPalette.warning).frame(width: 6, height: 6)
                        }
                        Text(reviewButtonTitle)
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(reviewAccessibilityLabel)
                .accessibilityIdentifier("transaction-review-queue-button")
            }
            HStack(spacing: 12) {
                transactionSearchField
                filterMenu
                Spacer(minLength: 0)
                if !visibleSelection.isEmpty { bulkActionBar }
            }
            if model.filterPeriod == .custom {
                customPeriodBar
            }
        }
        .padding(.horizontal, AppLayout.pageHorizontalPadding)
        .padding(.top, AppSpacing.xl)
        .padding(.bottom, AppSpacing.l)
        .workspaceCanvas()
        if let scope = model.inheritedAnalyticsScope {
            HStack {
                Text(scope.summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Analysefilter entfernen") { model.setMonthFilter(nil) }
                    .accessibilityIdentifier("transactions-clear-analytics-scope")
            }
            .padding(AppSpacing.m)
        }
        if model.inheritedAnalyticsScope == nil, let monthTitle = model.monthFilterTitle {
            HStack {
                Label(monthTitle, systemImage: "calendar")
                Spacer()
                Button("Monatsfilter entfernen") { model.setMonthFilter(nil) }
            }
            .font(.callout)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        if let error = model.errorMessage, !model.transactions.isEmpty {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle")
                Spacer()
                Button("Erneut laden") { Task { await model.refresh() } }
            }
            .font(.callout).padding(AppSpacing.m)
            .background(AppTone.warning.foregroundColor.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.medium))
            .padding(.horizontal, AppLayout.pageHorizontalPadding)
            .padding(.bottom, AppSpacing.s)
        }
    }

    @ViewBuilder
    private var transactionEmptyState: some View {
        if model.searchText.isEmpty, model.activeFilterCount > 0 {
            // Leer wegen Filter ≠ leer wegen fehlender Daten.
            EmptyStateView(
                title: String(localized: "Keine Treffer für diese Filter"),
                message: String(localized: "Mit den gewählten Filtern gibt es keine Buchungen."),
                systemImage: "line.3.horizontal.decrease.circle"
            ) {
                Button("Filter zurücksetzen") {
                    model.resetFilters()
                }
                .buttonStyle(.borderedProminent)
            }
        } else if model.searchText.isEmpty {
            EmptyStateView(
                title: String(localized: "Noch keine Transaktionen"),
                message: String(localized: "Verbinde eine Datenquelle oder erfasse die erste Transaktion manuell."),
                systemImage: "list.bullet.rectangle.fill"
            ) {
                HStack(spacing: AppSpacing.s) {
                    Button("Datenquelle hinzufügen") {
                        activeSheet = .addDataSource
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Transaktion erfassen") {
                        activeSheet = .addTransaction
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else {
            ContentUnavailableView.search(text: model.searchText)
        }
    }

    /// WP24: Deep-Link-Konsum, exaktes Ziel statt Sektionswechsel.
    private func consumePendingRoute() {
        guard let route = pendingRoute.wrappedValue else { return }
        pendingRoute.wrappedValue = nil
        switch route {
        case .transaction(let id):
            selection = [id]
            // P0: Deep-Link ist ein explizites Öffnungs-Ziel (kein
            // Auto-Open bei normaler Auswahl).
            inspector.openExplicitly()
        case .tag(let tagID):
            model.filterTagIDs = Set([tagID])
            model.tagFilterMode = .any
            Task { await model.refresh() }
        case .transactionsMonth(let interval):
            // MacUX-Audit: Cashflow-Klick → Monat gefiltert anzeigen.
            model.setMonthFilter(interval)
        case .transactionsScope(let scope):
            model.setAnalyticsScope(scope)
        case .reviewQueue:
            activeSheet = .reviewQueue
        default:
            break
        }
    }

    /// WP22: Quick-Actions nur bei aktiver Auswahl und OHNE Texteingabe-
    /// Fokus, der Buchstaben-Shortcut R schreibt sonst in das Suchfeld.
    private var transactionQuickActions: TransactionQuickActions? {
        let selectedTransactions = model.visibleTransactions.filter { selection.contains($0.id) }
        guard !selectedTransactions.isEmpty, !isSearchFocused else { return nil }
        let selectedIDs = Set(selectedTransactions.map(\.id))
        let reviewed = !selectedTransactions.allSatisfy(\.reviewed)
        return TransactionQuickActions(
            toggleReviewed: {
                Task { await model.bulkToggleReviewed(reviewed, for: selectedIDs) }
            },
            selectAll: { selection = Set(model.visibleTransactions.map(\.id)) },
            clearSelection: { selection = [] }
        )
    }

    /// P1 (Roadmap #26, #31): Undo/Redo nur ohne Suche-Fokus, sonst
    /// schreibt ⌘Z in das Suchfeld statt Transaktions-Edits zurückzunehmen.
    /// Die View ruft nur das Model auf (keine Business-Logik hier).
    private var transactionUndoActions: TransactionUndoActions? {
        guard !isSearchFocused else { return nil }
        guard model.canUndo || model.canRedo else {
            return TransactionUndoActions(
                undo: { Task { await model.undo() } },
                redo: { Task { await model.redo() } },
                canUndo: false,
                canRedo: false,
                undoName: nil,
                redoName: nil
            )
        }
        return TransactionUndoActions(
            undo: { Task { await model.undo() } },
            redo: { Task { await model.redo() } },
            canUndo: model.canUndo,
            canRedo: model.canRedo,
            undoName: model.undoActionName,
            redoName: model.redoActionName
        )
    }

    private var macToolbar: some ToolbarContent {
        ToolbarItemGroup {
            if model.canUndo || model.canRedo { undoRedoButtons }
            Button {
                activeSheet = .addTransaction
            } label: {
                Label("Neue Transaktion", systemImage: "plus.circle")
            }
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel("Neue Transaktion erfassen")
            .accessibilityIdentifier("transaction-add-button")
            .help("Neue Transaktion erfassen (⌘N)")

            Button {
                inspector.toggle()
            } label: {
                Label("Transaktionsdetails", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: .command)
            .accessibilityLabel(inspector.isPresented ? String(localized: "Transaktionsdetails ausblenden") : String(localized: "Transaktionsdetails einblenden"))
            .help(inspector.isPresented ? String(localized: "Transaktionsdetails ausblenden (⌘I)") : String(localized: "Transaktionsdetails einblenden (⌘I)"))


            #if !os(macOS)
            PrivacyToggleToolbarButton()
            #endif
        }
    }

    private var reviewButtonTitle: String {
        guard let reviewCount, reviewCount > 0 else { return String(localized: "Prüfliste") }
        return String(localized: "Prüfen · \(reviewCount)")
    }

    private var reviewAccessibilityLabel: String {
        reviewCount.map { String(localized: "Prüfliste öffnen, \($0) offen") } ?? String(localized: "Prüfliste öffnen")
    }

    /// P1: Toolbar Undo/Redo (nur Model aufrufen, Disabled-States +
    /// A11y-Labels). Shortcuts liefert das Edit-Menü (FinanceCommands).
    @ViewBuilder
    private var undoRedoButtons: some View {
        Button {
            Task { await model.undo() }
        } label: {
            Label("Rückgängig", systemImage: "arrow.uturn.backward")
        }
        .disabled(!model.canUndo)
        .accessibilityLabel(model.undoActionName.map { String(localized: "„\($0)“ rückgängig machen") } ?? String(localized: "Rückgängig machen (keine Aktion verfügbar)"))
        .accessibilityIdentifier("transaction-undo-button")

        Button {
            Task { await model.redo() }
        } label: {
            Label("Wiederholen", systemImage: "arrow.uturn.forward")
        }
        .disabled(!model.canRedo)
        .accessibilityLabel(model.redoActionName.map { String(localized: "„\($0)“ wiederholen") } ?? String(localized: "Wiederholen (keine Aktion verfügbar)"))
        .accessibilityIdentifier("transaction-redo-button")
    }

    /// Auswahl, die in der aktuellen Suche/Filterung sichtbar ist. Bulk-
    /// Aktionen dürfen nie auf weggefilterte, unsichtbare Zeilen wirken.
    private var visibleSelection: Set<Transaction.ID> {
        guard !selection.isEmpty else { return [] }
        return selection.intersection(model.visibleTransactions.map(\.id))
    }

    /// Bulk-Action-Bar (Roadmap #24): sichtbar ab 1 Auswahl.
    private var bulkActionBar: some View {
        Menu {
            Menu("Kategorie ändern") {
                Button("Ohne Kategorie") {
                    Task { await model.bulkChangeCategory(nil, for: visibleSelection); selection = [] }
                }
                Button("Neue Kategorie …") {
                    model.categoryCreationTarget = .selection(visibleSelection)
                }
                Divider()
                ForEach(model.assignableCategories) { cat in
                    Button(cat.name) {
                        Task { await model.bulkChangeCategory(cat.id, for: visibleSelection); selection = [] }
                    }
                }
            }

            tagBulkMenu

            Button("Als geprüft markieren") {
                Task { await model.bulkToggleReviewed(true, for: visibleSelection); selection = [] }
            }
            Button("Als ungeprüft markieren") {
                Task { await model.bulkToggleReviewed(false, for: visibleSelection); selection = [] }
            }

            Divider()
            Button("Aus Analyse ausschließen") {
                Task { await model.bulkExclude(true, for: visibleSelection); selection = [] }
            }
            Button("In Analyse einschließen") {
                Task { await model.bulkExclude(false, for: visibleSelection); selection = [] }
            }
        } label: {
            Label("\(visibleSelection.count) ausgewählt", systemImage: "checkmark.circle.fill")
        }
        .accessibilityLabel("\(visibleSelection.count) Transaktionen ausgewählt, Bulk-Aktionen")
    }

    /// Bulk-Tags (Roadmap #17): mehrere Tags hinzufügen/entfernen.
    private var tagBulkMenu: some View {
        Menu("Tags") {
            Menu("Hinzufügen") {
                ForEach(model.allTags) { tag in
                    Button(tag.name) {
                        Task { await model.bulkAddTag(tag.id, for: visibleSelection); selection = [] }
                    }
                }
            }
            Menu("Entfernen") {
                ForEach(model.allTags) { tag in
                    Button(tag.name) {
                        Task { await model.bulkRemoveTag(tag.id, for: visibleSelection); selection = [] }
                    }
                }
            }
            if model.allTags.isEmpty {
                Text("Noch keine Tags")
            }
        }
    }

    /// Datumsfelder für den frei gewählten Zeitraum, erscheinen nur, wenn
    /// im Filtermenü „Eigener Zeitraum …" gewählt ist (Datumsfelder lassen
    /// sich nicht in ein Menü legen).
    private var customPeriodBar: some View {
        @Bindable var model = model
        return HStack(spacing: AppSpacing.m) {
            Image(systemName: "calendar").foregroundStyle(.secondary)
            DatePicker(
                "Von",
                selection: $model.filterCustomStart,
                in: ...model.filterCustomEnd,
                displayedComponents: .date
            )
            .accessibilityIdentifier("transactions-filter-from")
            DatePicker(
                "Bis",
                selection: $model.filterCustomEnd,
                in: model.filterCustomStart...,
                displayedComponents: .date
            )
            .accessibilityIdentifier("transactions-filter-through")
            Button {
                model.filterPeriod = .all
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Zeitraumfilter entfernen")
            .accessibilityLabel("Zeitraumfilter entfernen")
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Eigener Zeitraum")
    }

    private var filterMenu: some View {
        Menu {
            // Ein Picker im Menü ist bereits ein Untermenü, ein zusätzliches
            // `Menu` ergab „Kategorie ▸ Kategorie ▸ …".
            Picker("Kategorie", selection: $model.filterCategoryID) {
                Text("Alle Kategorien").tag(UUID?.none)
                ForEach(model.parentCategories) { category in
                    Text(category.name).tag(UUID?.some(category.id))
                }
            }
            tagFilterMenu
            Picker("Konto", selection: $model.filterAccountID) {
                Text("Alle Konten").tag(UUID?.none)
                ForEach(model.filterableAccounts, id: \.id) { account in
                    Text(account.label).tag(UUID?.some(account.id))
                }
            }
            Picker("Zeitraum", selection: $model.filterPeriod) {
                ForEach(TransactionPeriodFilter.allCases) { period in
                    Text(period.displayName).tag(period)
                }
            }
            Picker("Status", selection: $model.filterStatus) {
                Text("Alle Status").tag(TransactionStatus?.none)
                ForEach(TransactionStatus.allCases, id: \.self) { status in
                    Text(status.displayName).tag(TransactionStatus?.some(status))
                }
            }
            if model.activeFilterCount > 0 {
                Divider()
                Button("Filter zurücksetzen") {
                    model.resetFilters()
                }
            }
        } label: {
            let activeCount = model.activeFilterCount
            Label(
                activeCount == 0 ? String(localized: "Filtern") : String(localized: "Filter (\(activeCount))"),
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityLabel("Transaktionen filtern")
    }

    /// Tag-Filter (Roadmap #16): mehrere Tags wählbar, ANY-Semantik.
    private var tagFilterMenu: some View {
        Menu {
            ForEach(model.allTags) { tag in
                Button {
                    if model.filterTagIDs.contains(tag.id) {
                        model.filterTagIDs.remove(tag.id)
                    } else {
                        model.filterTagIDs.insert(tag.id)
                    }
                    Task { await model.loadMoreForTagFilter() }
                } label: {
                    HStack {
                        Circle().fill(tag.colorToken.color).frame(width: 8, height: 8)
                        Text(tag.name)
                        if model.filterTagIDs.contains(tag.id) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if !model.filterTagIDs.isEmpty {
                Divider()
                Picker("Übereinstimmung", selection: $model.tagFilterMode) {
                    ForEach(TagFilterMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Button("Tag-Filter zurücksetzen") {
                    model.filterTagIDs = []
                }
            }
        } label: {
            Label(
                model.filterTagIDs.isEmpty ? String(localized: "Tags") : String(localized: "Tags (\(model.filterTagIDs.count))"),
                systemImage: "tag"
            )
        }
        .disabled(model.allTags.isEmpty)
        .accessibilityLabel("Nach Tags filtern")
    }
}

/// MacUX-Audit (Inspector-Lag): Die Tabelle lebt in einem eigenen View-
/// Kontext. Vorher evaluierte `MacTransactionsContent.body` Table UND
/// Inspector-Inhalt in einer Observation-Kette, jeder Inspector-Toggle
/// oder Toolbar-Zustandswechsel baute die komplette Tabelle (mit allen
/// Zeilenzellen) während der Ausfahr-Animation neu. Jetzt enthält der
/// Body des Parents nur noch leichte Zustands-Views; SwiftUI überspringt
/// das Table-Child, wenn dessen Inputs unverändert sind.
private struct MacTransactionsTable: View {
    let model: TransactionsModel
    @Binding var selection: Set<Transaction.ID>

    var body: some View {
        @Bindable var model = model
        Table(model.visibleTransactions, selection: $selection, sortOrder: $model.tableSortOrder) {
            TableColumn("Datum", value: \.displayDate) { txn in
                dateCell(txn)
            }

            TableColumn("Händler", value: \.effectiveMerchantName) { txn in
                merchantCell(txn)
            }

            TableColumn("Konto") { txn in
                accountCell(txn)
            }

            TableColumn("Kategorie") { txn in
                withTransactionContextMenu(txn, categoryCell(txn))
            }

            TableColumn("Betrag", value: \.amountSortValue) { txn in
                amountCell(txn)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 240
        } action: { _, nearEnd in
            guard nearEnd, let last = model.transactions.last else { return }
            Task { await model.loadMoreIfNeeded(for: last) }
        }
        .overlay(alignment: .bottom) {
            if model.isLoadingPage {
                ProgressView()
                    .padding(AppSpacing.s)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                (model.canLoadMore
                    ? Text("\(model.visibleTransactions.count) angezeigt · weitere Buchungen verfügbar")
                    : Text("\(model.visibleTransactions.count) angezeigt"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.canLoadMore {
                    Button("Weitere laden") {
                        Task {
                            if !model.filterTagIDs.isEmpty {
                                await model.loadMoreForTagFilter()
                            } else if let last = model.transactions.last {
                                await model.loadMoreIfNeeded(for: last)
                            }
                        }
                    }
                    .disabled(model.isLoadingPage || model.tagFilterLoading)
                    .accessibilityLabel("Weitere Buchungen für die aktuelle Filterung laden")
                }
            }
            .padding(AppSpacing.s)
            // Fußzeile als eigene Leiste: Ohne Hintergrund lag sie über der
            // letzten Tabellenzeile (vorher wegen des überhohen Inspector-
            // Containers gar nicht sichtbar).
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func dateCell(_ txn: Transaction) -> some View {
        withTransactionContextMenu(
            txn,
            Text(AppDateFormatter.weekdayDay(txn.displayDate))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        )
    }

    private func merchantCell(_ txn: Transaction) -> some View {
        withTransactionContextMenu(
            txn,
            HStack(spacing: 6) {
                Text(txn.effectiveMerchantName)
                    .fontWeight(.medium)
                    .strikethrough(isVoided(txn))
                    .opacity(isVoided(txn) ? 0.55 : 1)
                    .accessibilityIdentifier("transaction-row-\(txn.id.uuidString)")
                    // Der Händler bleibt lesbar; die Notiz weicht zuerst.
                    .layoutPriority(1)
                if let note = txn.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(note)
                        .accessibilityLabel("Notiz: \(note)")
                }
            }
        )
    }

    private func accountCell(_ txn: Transaction) -> some View {
        withTransactionContextMenu(
            txn,
            Text(model.accountLabelsByID[txn.accountID] ?? "–")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        )
    }

    /// WP-MacUX: Statischer Text statt interaktivem Menu pro Zeile,
    /// Menüs in jeder Tabellen-Zeile verursachen Scroll-Hitches. Die
    /// Kategorie-Änderung läuft über das Kontextmenü ( Rechtsklick).
    private func categoryCell(_ txn: Transaction) -> some View {
        let category = model.category(for: txn)
        return withTransactionContextMenu(
            txn,
            HStack(spacing: 6) {
                if let category {
                    IconTile(systemName: category.systemIconName, color: category.colorToken.color, size: 20)
                    Text(category.name)
                } else {
                    Text("–")
                        .foregroundStyle(.secondary)
                }
            }
            // Gleiche Zeilenhöhe mit und ohne Kategorie-Symbol.
            .frame(minHeight: 20)
            .font(.callout)
        )
    }

    /// Stornierte und rückgängig gemachte Buchungen zählen in keiner
    /// Auswertung, in der Liste sind sie durchgestrichen und abgeblendet,
    /// sonst sähen sie aus wie eine doppelte Abbuchung.
    private func isVoided(_ txn: Transaction) -> Bool {
        txn.status == .cancelled || txn.status == .reversed
    }

    private func amountCell(_ txn: Transaction) -> some View {
        let voided = isVoided(txn)
        return withTransactionContextMenu(
            txn,
            MoneyText(money: txn.amount, signed: true)
                .strikethrough(voided)
                .opacity(voided ? 0.55 : 1)
                .help(voided ? String(localized: "\(txn.status.displayName) (zählt nicht in Auswertungen)") : "")
                .accessibilityValue(voided ? txn.status.displayName : "")
        )
    }

    /// Context-Menü-Inhalt für eine Transaktion (Roadmap #166).
    private func transactionMenuItems(_ txn: Transaction) -> some View {
        Group {
            Menu("Kategorie") {
                Button("Ohne Kategorie") {
                    Task { await model.changeCategory(txn, to: nil) }
                }
                Button("Neue Kategorie …") {
                    model.categoryCreationTarget = .transaction(txn)
                }
                Divider()
                // Leaf-only: Hauptkategorien mit Unterkategorien
                // sind nur Gruppen; Hauptkategorien ohne Kinder sind direkt
                // wählbar statt hinter einem gleichnamigen Untermenü.
                ForEach(model.parentCategories) { parent in
                    let children = model.categories.filter { $0.parentID == parent.id }
                    if children.isEmpty {
                        Button(parent.name) {
                            Task { await model.changeCategory(txn, to: parent.id) }
                        }
                    } else {
                        Menu(parent.name) {
                            ForEach(children) { child in
                                Button(child.name) {
                                    Task { await model.changeCategory(txn, to: child.id) }
                                }
                            }
                        }
                    }
                }
            }

            Menu("Tags") {
                if model.allTags.isEmpty {
                    Text("Noch keine Tags")
                }
                ForEach(model.allTags) { tag in
                    Button {
                        Task { await model.toggleTag(tag.id, on: txn) }
                    } label: {
                        HStack {
                            Text(tag.name)
                            if (txn.tagIDs ?? []).contains(tag.id) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Button(txn.reviewed ? String(localized: "Als ungeprüft markieren") : String(localized: "Als geprüft markieren")) {
                Task { await model.toggleReviewed(txn, reviewed: !txn.reviewed) }
            }

            Button(txn.excludedFromAnalytics ? String(localized: "In Analyse einschließen") : String(localized: "Aus Analyse ausschließen")) {
                Task { await model.toggleExcluded(txn, excluded: !txn.excludedFromAnalytics) }
            }

            Divider()
            Menu("Typ") {
                Button("Ausgabe") { Task { await model.setManualKind(.purchase, on: txn) } }
                Button("Einnahme") { Task { await model.setManualKind(.income, on: txn) } }
                // Eine Erstattung ist ein Zahlungseingang, der Ausgaben mindert.
                if !txn.amount.isNegative {
                    Button("Erstattung") { Task { await model.setManualKind(.refund, on: txn) } }
                }
                Button("Transfer") { Task { await model.setManualKind(.transfer, on: txn) } }
                Divider()
                Button("Erkennung wiederherstellen") { Task { await model.setManualKind(nil, on: txn) } }
            }
            cashWithdrawalMenuItems(txn)
            if model.canDeleteManually(txn) {
                Divider()
                if model.canEditManually(txn) {
                    Button("Bearbeiten …") { model.transactionPendingEdit = txn }
                }
                Button("Löschen …", role: .destructive) { model.transactionPendingDeletion = txn }
            }
        }
    }

    /// Bargeldabhebung: Ausgabe eines anderen Kontos als Transfer ins
    /// Bargeldkonto buchen (Gegenbuchung +Betrag).
    @ViewBuilder
    private func cashWithdrawalMenuItems(_ txn: Transaction) -> some View {
        let targets = model.cashAccounts.filter { $0.id != txn.accountID }
        // Ein Transfer hat bereits seine Gegenbuchung.
        if txn.amount.isNegative, txn.kind != .transfer, !targets.isEmpty {
            if targets.count == 1, let cash = targets.first {
                Button("Als Abhebung in „\(cash.name)“ gutschreiben") {
                    Task { await model.mirrorCashWithdrawal(txn, into: cash) }
                }
            } else {
                Menu("Als Abhebung gutschreiben") {
                    ForEach(targets) { cash in
                        Button(cash.name) { Task { await model.mirrorCashWithdrawal(txn, into: cash) } }
                    }
                }
            }
        }
    }

    private func withTransactionContextMenu<V: View>(_ txn: Transaction, _ content: V) -> some View {
        content.contextMenu { transactionMenuItems(txn) }
    }
}

/// MacUX-Audit (Inspector-Lag): Inspector-Inhalt in eigenem View-Kontext,
/// der Aufbau des Detail-Formulars (oder der Bulk-Summary) invalidiert
/// nicht mehr den Screen-Body, und Privacy-Wechsel wirken nur hier und
/// in den MoneyText-Zellen.
///
/// Runde 2 („jede Zeile wird einzeln verschoben"): Der komplette Form-
/// Aufbau (8 Sections, Picker, Menüs) lief SYNCHRON beim Start der
/// Ausfahr-Animation und blockierte die ersten Animationsframes, die
/// Tabelle schob ihre Zeilen dadurch ruckartig-staffelnd. Der Content
/// wird jetzt erst nach dem Animationsfenster gebaut; die Pane zeigt
/// währenddessen einen leichten Placeholder. Bei Auswahlwechsel im
/// offenen Inspector wird sofort gewechselt (keine Verzögerung).
private struct TransactionInspectorPane: View {
    let model: TransactionsModel
    let selection: Set<Transaction.ID>
    let isPresented: Bool

    @State private var showsContent = false
    @Environment(PrivacyPresentationState.self) private var privacyState

    var body: some View {
        Group {
            if showsContent {
                content
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Die Pane existiert nur im geöffneten Zustand (fester HStack statt
        // `.inspector`), daher baut `.task` den Inhalt nach einem kurzen
        // Frame-Fenster auf, ein `onChange(of: isPresented)` würde nie
        // feuern und den Platzhalter endlos stehen lassen.
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            showsContent = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if selection.count > 1 {
            // WP23 (§168): Mehrfachauswahl zeigt eine Bulk-Summary statt
            // einer einzelnen zufälligen Transaktion.
            multiSelectionSummary
        } else if let id = selection.first, model.transaction(withID: id) != nil {
            TransactionDetailView(model: model, transactionID: id)
        } else {
            ContentUnavailableView(
                "Keine Auswahl",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Wähle eine Transaktion aus, um Details zu sehen.")
            )
        }
    }

    /// WP23 (§168): Bulk-Zusammenfassung der Mehrfachauswahl.
    private var multiSelectionSummary: some View {
        let byID = Dictionary(uniqueKeysWithValues: model.transactions.map { ($0.id, $0) })
        let selected = selection.compactMap { byID[$0] }
        // Summen je Währung, ohne Umrechnung werden Währungen nie addiert.
        let totals = Dictionary(grouping: selected, by: \.amount.currency)
            .mapValues { $0.reduce(Decimal(0)) { $0 + $1.amount.amount } }
            .sorted { $0.key.rawValue < $1.key.rawValue }
        return VStack(alignment: .leading, spacing: AppSpacing.m) {
            Label(
                selected.count == 1 ? String(localized: "1 Transaktion ausgewählt") : String(localized: "\(selected.count) Transaktionen ausgewählt"),
                systemImage: "checklist"
            )
            .font(.headline)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                (totals.count > 1 ? Text("Summen der Auswahl je Währung") : Text("Summe der Auswahl"))
                    .eyebrowStyle()
                ForEach(totals, id: \.key) { currency, total in
                    Text(PrivacyAwareMoney.decimalString(total, currency: currency, privacy: privacyState))
                        .font(AppTypography.largeMetric)
                        .monospacedDigit()
                }
            }

            Text("Bulk-Aktionen (Kategorie, Tags, Prüfstatus) findest du in der Toolbar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(AppSpacing.m)
    }
}

#else

private struct MobileTransactionsContent: View {
    @State private var model: TransactionsModel
    @State private var activeSheet: MobileTransactionSheet?
    @FocusState private var isSearchFocused: Bool

    private enum MobileTransactionSheet: String, Identifiable {
        case addTransaction
        case filters
        case reviewQueue
        var id: String { rawValue }
    }

    /// WP24: Ausstehende Palette-Route (Transaktion/Tag), konsumiert beim
    /// ersten Aufbau der Ansicht.
    var pendingRoute: Binding<PaletteRoute?>
    let reviewCount: Int?

    init(dependencies: AppDependencies, pendingRoute: Binding<PaletteRoute?>, reviewCount: Int?) {
        _model = State(initialValue: TransactionsModel(dependencies: dependencies))
        self.pendingRoute = pendingRoute
        self.reviewCount = reviewCount
    }

    var body: some View {
        @Bindable var model = model
        mobileContent
            .searchable(text: $model.searchText, prompt: "Händler oder Beschreibung")
            .toolbar { mobileToolbar }
            .manualTransactionPresenter(model)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .addTransaction:
                    AddTransactionSheet(dependencies: model.dependencies) {
                        Task { await model.refresh() }
                    }
                case .filters:
                    MobileTransactionsFilterSheet(model: model) {
                        Task { await model.loadMoreForTagFilter() }
                    }
                case .reviewQueue:
                    ReviewQueueView(dependencies: model.dependencies, showsDismissButton: true)
                }
            }
            .navigationTitle("Transaktionen")
            .task(id: model.dataRevision) {
                await model.refresh()
                consumePendingRoute()
            }
            .onChange(of: pendingRoute.wrappedValue) { _, route in
                guard route != nil else { return }
                consumePendingRoute()
            }
            .onChange(of: model.filterTagIDs) { _, _ in
                Task { await model.loadMoreForTagFilter() }
            }
    }

    private var mobileContent: some View {
        Group {
            if let errorMessage = model.errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await model.refresh() }
                }
            } else if model.transactions.isEmpty {
                if model.isLoading {
                    LoadingStateView()
                } else {
                    EmptyStateView(
                        title: String(localized: "Keine Transaktionen"),
                        message: model.searchText.isEmpty
                            ? String(localized: "Es sind noch keine Transaktionen vorhanden.")
                            : String(localized: "Keine Treffer für „\(model.searchText)“."),
                        systemImage: "list.bullet.rectangle"
                    )
                }
            } else {
                transactionList
            }
        }
    }

    private var mobileToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await model.undo() }
            } label: {
                Label("Rückgängig", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .accessibilityLabel(model.undoActionName.map { String(localized: "„\($0)“ rückgängig machen") } ?? String(localized: "Rückgängig machen (keine Aktion verfügbar)"))
            .accessibilityIdentifier("transaction-undo-button")

            Button {
                Task { await model.redo() }
            } label: {
                Label("Wiederholen", systemImage: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .accessibilityLabel(model.redoActionName.map { String(localized: "„\($0)“ wiederholen") } ?? String(localized: "Wiederholen (keine Aktion verfügbar)"))
            .accessibilityIdentifier("transaction-redo-button")

            Button {
                activeSheet = .addTransaction
            } label: {
                Label("Neue Transaktion", systemImage: "plus.circle")
            }
            .accessibilityLabel("Neue Transaktion erfassen")
            .accessibilityIdentifier("transaction-add-button")

            Button {
                activeSheet = .reviewQueue
            } label: {
                Label("Prüfen", systemImage: "checkmark.circle")
            }
            .accessibilityLabel(reviewCount.map { String(localized: "Prüfliste öffnen, \($0) offen") } ?? String(localized: "Prüfliste öffnen"))
            .accessibilityIdentifier("transaction-review-queue-button")

            Button {
                activeSheet = .filters
            } label: {
                Label("Filtern & Sortieren", systemImage: "line.3.horizontal.decrease.circle")
            }
            .overlay(alignment: .topTrailing) {
                if hasActiveFilters {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8).offset(x: 8, y: -2)
                }
            }
            .accessibilityLabel("Filter und Sortierung öffnen")

            PrivacyToggleToolbarButton()
        }
    }

    private var hasActiveFilters: Bool {
        model.activeFilterCount > 0
            || model.selectedSort != .dateDescending
    }

    private func consumePendingRoute() {
        guard case .reviewQueue = pendingRoute.wrappedValue else { return }
        pendingRoute.wrappedValue = nil
        activeSheet = .reviewQueue
    }

    private var transactionList: some View {
        List {
            ForEach(model.visibleTransactions) { txn in
                NavigationLink(value: txn.id) {
                    TransactionRowView(transaction: txn, category: model.category(for: txn))
                        .accessibilityElement(children: .combine)
                        .onAppear {
                            Task { await model.loadMoreIfNeeded(for: txn) }
                        }
                }
                .contextMenu {
                    categoryContextMenu(for: txn)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        Task { await model.changeCategory(txn, to: nil) }
                    } label: {
                        Label("Kategorie entfernen", systemImage: "tag.slash")
                    }
                    .tint(.secondary)

                    Menu {
                        // WP12: Leaf-only Zuweisung (Parents = aggregation-only).
                        ForEach(model.assignableCategories) { category in
                            Button(category.name) {
                                Task { await model.changeCategory(txn, to: category.id) }
                            }
                        }
                        Divider()
                        Button("Neue Kategorie …") {
                            model.categoryCreationTarget = .transaction(txn)
                        }
                    } label: {
                        Label("Kategorie ändern", systemImage: "tag")
                    }
                    .tint(.accentColor)
                }
            }
        }
        .listStyle(.plain)
        .overlay(alignment: .bottom) {
            if model.isLoadingPage {
                ProgressView()
                    .padding(AppSpacing.s)
            }
        }
        .navigationDestination(for: UUID.self) { id in
            if model.transaction(withID: id) != nil {
                TransactionDetailView(model: model, transactionID: id)
            } else {
                EmptyView()
            }
        }
        .refreshable { await model.refresh() }
        .onChange(of: model.searchText) { _, _ in
            model.searchTextChanged()
        }
        .onChange(of: model.selectedSort) { _, _ in
            model.filterChanged()
        }
        .onChange(of: model.filterCategoryID) { _, _ in
            model.filterChanged()
        }
    }

    @ViewBuilder
    private func categoryContextMenu(for txn: Transaction) -> some View {
        Menu {
            Picker("Kategorie", selection: Binding(
                get: { txn.categoryID },
                set: { newValue in
                    Task { await model.changeCategory(txn, to: newValue) }
                }
            )) {
                Text("Ohne Kategorie").tag(UUID?.none)
                // WP12: Leaf-only Zuweisung (Parents = aggregation-only).
                ForEach(model.assignableCategories) { category in
                    Text(category.name).tag(UUID?.some(category.id))
                }
            }
            Divider()
            Button("Neue Kategorie …") {
                model.categoryCreationTarget = .transaction(txn)
            }
        } label: {
            Label("Kategorie ändern", systemImage: "tag")
        }
    }

}

#endif


private struct MobileTransactionsFilterSheet: View {
    @Bindable var model: TransactionsModel
    let onTagFilterChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Sortierung") {
                    Picker("Reihenfolge", selection: $model.selectedSort) {
                        ForEach(TransactionSortOrder.allCases, id: \.self) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Kategorie") {
                    Picker("Kategorie", selection: $model.filterCategoryID) {
                        Text("Alle Kategorien").tag(UUID?.none)
                        ForEach(model.parentCategories) { category in
                            Text(category.name).tag(UUID?.some(category.id))
                        }
                    }
                }
                Section("Konto, Zeitraum, Status") {
                    Picker("Konto", selection: $model.filterAccountID) {
                        Text("Alle Konten").tag(UUID?.none)
                        ForEach(model.filterableAccounts, id: \.id) { account in
                            Text(account.label).tag(UUID?.some(account.id))
                        }
                    }
                    Picker("Zeitraum", selection: $model.filterPeriod) {
                        ForEach(TransactionPeriodFilter.allCases) { period in
                            Text(period.displayName).tag(period)
                        }
                    }
                    if model.filterPeriod == .custom {
                        DatePicker("Von", selection: $model.filterCustomStart, in: ...model.filterCustomEnd, displayedComponents: .date)
                        DatePicker("Bis", selection: $model.filterCustomEnd, in: model.filterCustomStart..., displayedComponents: .date)
                    }
                    Picker("Status", selection: $model.filterStatus) {
                        Text("Alle Status").tag(TransactionStatus?.none)
                        ForEach(TransactionStatus.allCases, id: \.self) { status in
                            Text(status.displayName).tag(TransactionStatus?.some(status))
                        }
                    }
                }
                Section("Tags") {
                    if !model.filterTagIDs.isEmpty {
                        Picker("Übereinstimmung", selection: $model.tagFilterMode) {
                            ForEach(TagFilterMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
            .labelsHidden()
                    }
                    if model.allTags.isEmpty {
                        Text("Noch keine Tags").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.allTags) { tag in
                            Button {
                                if model.filterTagIDs.contains(tag.id) {
                                    model.filterTagIDs.remove(tag.id)
                                } else {
                                    model.filterTagIDs.insert(tag.id)
                                }
                                onTagFilterChanged()
                            } label: {
                                HStack {
                                    Circle().fill(tag.colorToken.color).frame(width: 8, height: 8)
                                    Text(tag.name)
                                    Spacer()
                                    if model.filterTagIDs.contains(tag.id) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filtern & Sortieren")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#if DEBUG
#Preview("Transaktionen") {
    NavigationStack {
        TransactionsView(
            dependencies: PreviewDependencies.dependencies(),
            pendingRoute: .constant(nil)
        )
    }
    .environment(PrivacyPresentationState())
}
#endif
