import SwiftUI

struct PocketsView: View {
    private let dependencies: AppDependencies
    @State private var model: PocketsModel
    @State private var activeSheet: PocketSheet?
    @State private var pendingDeletion: TransactionCollection?
    @Environment(PrivacyPresentationState.self) private var privacyState

    private enum PocketSheet: Identifiable {
        case create
        case edit(TransactionCollection)
        case addTransaction
        case addDataSource

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let collection): "edit-\(collection.id.uuidString)"
            case .addTransaction: "add-transaction"
            case .addDataSource: "add-data-source"
            }
        }
    }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _model = State(initialValue: PocketsModel(dependencies: dependencies))
    }

    var body: some View {
        Group {
            if model.isLoading, model.items.isEmpty {
                LoadingStateView(label: String(localized: "Lade Sammlungen…"))
            } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                ErrorStateView(message: errorMessage) {
                    Task { await model.load() }
                }
                .accessibilityIdentifier("screen-ready-pockets")
            } else if model.items.isEmpty {
                emptyState
            } else {
                #if os(macOS)
                macWorkspace
                #else
                mobileWorkspace
                #endif
            }
        }
        .workspaceNavigationTitle(String(localized: "Sammlungen"))
        .workspaceHeading(
            String(localized: "Sammlungen"),
            subtitle: String(localized: "Reisen, Projekte und gemeinsame Ausgaben zusammenfassen"),
            eyebrow: String(localized: "Organisation")
        )
        .workspaceCanvas()
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = model.errorMessage, !model.items.isEmpty {
                errorBanner(errorMessage)
            }
        }
        .workspaceToolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    activeSheet = .create
                } label: {
                    Label("Neue Sammlung", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .accessibilityIdentifier("pocket-add-button")
                .help("Neue Sammlung anlegen (⇧⌘N)")

            #if !os(macOS)
                PrivacyToggleToolbarButton()
            #endif
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .create:
                PocketEditorSheet(model: model, editing: nil)
            case .edit(let collection):
                PocketEditorSheet(model: model, editing: collection)
            case .addTransaction:
                PocketTransactionPicker(model: model)
            case .addDataSource:
                AddDataSourceView(dependencies: dependencies, onDismiss: { activeSheet = nil })
                    #if os(macOS)
                    .frame(width: 520, height: 620)
                    #endif
            }
        }
        .confirmationDialog(
            "Sammlung löschen?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                guard let collection = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await model.delete(collection) }
            }
            Button("Abbrechen", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Die Sammlung und ihre manuellen Zuordnungen werden gelöscht. Die Transaktionen bleiben unverändert.")
        }
        .task(id: model.dataRevision) { await model.load() }
    }

    private var emptyState: some View {
        EmptyStateView(
            title: String(localized: "Noch keine Sammlungen"),
            message: String(localized: "Fasse Reisen, Projekte oder gemeinsame Ausgaben nach Zeitraum und Konten zusammen. Analysen und Budgets bleiben unverändert."),
            systemImage: "square.stack.3d.up.fill"
        ) {
            if model.activeAccounts.isEmpty {
                Button("Konto hinzufügen") { activeSheet = .addDataSource }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("collections-add-account")
                Text("Für eine Sammlung brauchst du zuerst ein aktives Konto oder eine Karte.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Erste Sammlung erstellen") { activeSheet = .create }
                    .buttonStyle(.borderedProminent)
            }
        }
        .accessibilityIdentifier("screen-ready-pockets")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: AppSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppPalette.warning)
            Text(message)
                .font(.callout)
            Spacer()
            Button("Erneut versuchen") { Task { await model.load() } }
            Button {
                model.clearError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Fehlermeldung schließen")
            .help("Fehlermeldung schließen")
        }
        .padding(.horizontal, AppSpacing.m)
        .padding(.vertical, AppSpacing.s)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    #if os(macOS)
    private var macWorkspace: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 760 {
                HStack(spacing: AppSpacing.l) {
                    pocketList
                        .scrollContentBackground(.hidden)
                        .frame(width: 272)
                        .background(AppPalette.card)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous).strokeBorder(AppPalette.hairline))
                    pocketDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppPalette.card)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous).strokeBorder(AppPalette.hairline))
                }
                .padding(.horizontal, AppLayout.pageHorizontalPadding)
                .padding(.bottom, AppLayout.pageHorizontalPadding)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if model.selectedItem != nil {
                        Button { model.selectedCollectionID = nil } label: {
                            Label("Alle Sammlungen", systemImage: "chevron.left")
                        }
                        .padding(AppSpacing.m)
                        Divider()
                        pocketDetail
                    } else {
                        pocketList
                    }
                }
            }
        }
        .accessibilityIdentifier("screen-ready-pockets")
    }

    @ViewBuilder
    private var pocketDetail: some View {
        if let item = model.selectedItem {
            PocketMacDetail(
                item: item,
                rows: model.selectedRows,
                excludedRows: model.selectedExcludedRows,
                isMutating: model.isMutating,
                onEdit: { activeSheet = .edit(item.collection) },
                onDelete: { pendingDeletion = item.collection },
                onAddTransaction: { activeSheet = .addTransaction },
                onExclude: { transaction in Task { await model.exclude(transaction) } },
                onRestore: { transaction in Task { await model.restoreAutomation(for: transaction) } }
            )
            .id(item.id)
        } else {
            ContentUnavailableView(
                "Keine Sammlung ausgewählt",
                systemImage: "square.stack.3d.up",
                description: Text("Wähle links eine Sammlung aus.")
            )
        }
    }

    private var pocketList: some View {
        List(selection: $model.selectedCollectionID) {
            ForEach(PocketStatus.allCases) { status in
                let statusItems = model.items(status: status)
                if !statusItems.isEmpty {
                    Section(status.title) {
                        ForEach(statusItems) { item in
                            pocketListRow(item)
                                .tag(item.id)
                                .contextMenu {
                                    Button("Bearbeiten") { activeSheet = .edit(item.collection) }
                                    Button("Löschen", role: .destructive) { pendingDeletion = item.collection }
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .background(Color.clear)
        .accessibilityLabel("Sammlungsliste")
        .accessibilityIdentifier("screen-ready-pockets")
        .onDeleteCommand {
            guard let collection = model.selectedItem?.collection else { return }
            pendingDeletion = collection
        }
    }

    private func pocketListRow(_ item: PocketListItem) -> some View {
        HStack(spacing: AppSpacing.s) {
            IconTile(systemName: item.collection.systemIconName, color: AppPalette.brand, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.collection.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("\(periodText(item.collection)) · \(pocketAccountCountText(item.collection.accountIDs.count))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    netSummaryText(item)
                        .monospacedDigit()
                    Text("· \(item.snapshot.transactions.count) Buchungen")
                }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pocket-row-\(item.collection.name)")
        .accessibilityLabel("Sammlung \(item.collection.name), \(periodText(item.collection))")
    }

    /// Kompakte Netto-Zeile: alle Währungen inline (z. B. „1.234,56 € · -20,00 $“).
    private func netSummaryText(_ item: PocketListItem) -> Text {
        let summaries = PocketCurrencySummaryPresentation.rows(from: item.snapshot.currencySummaries)
        guard !summaries.isEmpty else {
            return Text("Keine Beträge").foregroundStyle(.tertiary)
        }
        let parts = summaries.map { summary in
            "\(PrivacyAwareMoney.decimalString(summary.netCashflow, currency: summary.currency, privacy: privacyState)) \(summary.currency.rawValue)"
        }
        return Text(parts.joined(separator: " · "))
    }
    #endif

    #if os(iOS)
    private var mobileWorkspace: some View {
        List {
            ForEach(PocketStatus.allCases) { status in
                let statusItems = model.items(status: status)
                if !statusItems.isEmpty {
                    Section(status.title) {
                        ForEach(statusItems) { item in
                            NavigationLink {
                                PocketMobileDetail(
                                    model: model,
                                    collectionID: item.id,
                                    onEdit: { activeSheet = .edit(item.collection) },
                                    onDelete: { pendingDeletion = item.collection },
                                    onAddTransaction: { activeSheet = .addTransaction }
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Label(item.collection.name, systemImage: item.collection.systemIconName)
                                        .fontWeight(.semibold)
                                    Text("\(periodText(item.collection)) · \(pocketAccountCountText(item.collection.accountIDs.count))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("screen-ready-pockets")
        .refreshable { await model.load() }
    }
    #endif

    private func periodText(_ collection: TransactionCollection) -> String {
        let inclusiveEnd = Calendar.current.date(
            byAdding: .day,
            value: -1,
            to: collection.endDateExclusive
        ) ?? collection.endDateExclusive
        return "\(AppDateFormatter.day(collection.startDate)) – \(AppDateFormatter.day(inclusiveEnd))"
    }
}

/// „1 Konto" bzw. „N Konten" für Listen- und Detailzeilen.
private func pocketAccountCountText(_ count: Int) -> String {
    count == 1 ? String(localized: "\(count) Konto") : String(localized: "\(count) Konten")
}

#if os(macOS)
private struct PocketMacDetail: View {
    let item: PocketListItem
    let rows: [PocketTransactionRow]
    let excludedRows: [PocketTransactionRow]
    let isMutating: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onAddTransaction: () -> Void
    let onExclude: (Transaction) -> Void
    let onRestore: (Transaction) -> Void

    @State private var displayMode: DisplayMode = .included
    @State private var selection: Set<PocketTransactionRow.ID> = []
    @State private var sortOrder = [KeyPathComparator(\PocketTransactionRow.date, order: .reverse)]
    @Environment(PrivacyPresentationState.self) private var privacyState

    private enum DisplayMode: String, CaseIterable, Identifiable {
        case included
        case excluded

        var id: Self { self }
        var title: String {
            switch self {
            case .included: String(localized: "Enthalten")
            case .excluded: String(localized: "Ausgeschlossen")
            }
        }
    }

    private var visibleRows: [PocketTransactionRow] {
        (displayMode == .included ? rows : excludedRows).sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            summary
            Divider()
            controls
            if visibleRows.isEmpty {
                ContentUnavailableView {
                    Label(
                        displayMode == .included
                            ? String(localized: "Noch keine Transaktionen")
                            : String(localized: "Nichts ausgeschlossen"),
                        systemImage: displayMode == .included ? "tray" : "checkmark.circle"
                    )
                } description: {
                    displayMode == .included
                        ? Text("Im Zeitraum und den gewählten Konten wurde noch nichts gefunden.")
                        : Text("Manuell ausgeschlossene Transaktionen erscheinen hier.")
                }
            } else {
                transactionTable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("screen-ready-pockets-detail")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: AppSpacing.m) {
            IconTile(systemName: item.collection.systemIconName, color: AppPalette.brand, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.collection.name)
                    .font(.title3.weight(.bold))
                Label(item.status.title, systemImage: item.status.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Bearbeiten", action: onEdit)
                .keyboardShortcut(.return, modifiers: [.command])
            Menu {
                Button("Löschen", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Weitere Aktionen für Sammlung")
            .help("Weitere Aktionen")
        }
        .padding(.horizontal, AppSpacing.l)
        .padding(.top, AppSpacing.l)
        .padding(.bottom, AppSpacing.m)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            let summaries = PocketCurrencySummaryPresentation.rows(from: item.snapshot.currencySummaries)
            if summaries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Noch keine Bewegung")
                        .font(.title2.weight(.semibold))
                    Text("\(rows.count) Transaktionen im ausgewählten Zeitraum")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: AppSpacing.xl) {
                        ForEach(summaries) { summary in
                            currencySummary(summary)
                            if summary.id != summaries.last?.id {
                                Divider().frame(height: 54)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            HStack(spacing: AppSpacing.m) {
                Label(periodText, systemImage: "calendar")
                Label(
                    pocketAccountCountText(item.collection.accountIDs.count),
                    systemImage: "creditcard"
                )
                Label("Nur Ansicht", systemImage: "eye")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.l)
        .padding(.bottom, AppSpacing.m)
    }

    private var periodText: String {
        let inclusiveEnd = Calendar.current.date(
            byAdding: .day,
            value: -1,
            to: item.collection.endDateExclusive
        ) ?? item.collection.endDateExclusive
        return "\(AppDateFormatter.day(item.collection.startDate)) – \(AppDateFormatter.day(inclusiveEnd))"
    }

    private func currencySummary(_ summary: PocketCurrencySummaryPresentation) -> some View {
        HStack(alignment: .bottom, spacing: AppSpacing.xl) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Netto · \(summary.currency.rawValue)")
                    .eyebrowStyle()
                Text(PrivacyAwareMoney.signedTotal(summary.netCashflow, kind: .balance, currency: summary.currency, privacy: privacyState))
                    .font(AppTypography.largeMetric.monospacedDigit())
                    .foregroundStyle(
                        privacyState.hidesAmounts || summary.netCashflow == 0
                            ? Color.primary
                            : (summary.netCashflow > 0 ? AppPalette.positive : AppPalette.critical)
                    )
            }
            metric(String(localized: "Einnahmen"), value: summary.income, kind: .income, currency: summary.currency)
            metric(String(localized: "Ausgaben"), value: summary.spending, kind: .expense, currency: summary.currency)
        }
        .accessibilityElement(children: .contain)
    }

    private func metric(_ title: String, value: Decimal, kind: PrivacyAwareMoney.SignedKind, currency: CurrencyCode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .eyebrowStyle()
            Text(PrivacyAwareMoney.signedTotal(value, kind: kind, currency: currency, privacy: privacyState))
                .font(AppTypography.compactMetric.monospacedDigit())
                .foregroundStyle(value == 0 || privacyState.hidesAmounts ? Color.primary : (kind == .income ? AppPalette.positive : AppPalette.critical))
                .accessibilityLabel(
                    "\(title), \(PrivacyAwareMoney.accessibilityLabel(value, currency: currency, privacy: privacyState))"
                )
        }
    }

    private var controls: some View {
        HStack(spacing: AppSpacing.m) {
            Picker("Transaktionen", selection: $displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode == .excluded ? "\(mode.title) (\(excludedRows.count))" : mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer()
            Button(action: onAddTransaction) {
                Label("Transaktion hinzufügen", systemImage: "plus")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(isMutating)
            .accessibilityIdentifier("pocket-add-transaction-button")
        }
        .padding(.horizontal, AppSpacing.m)
        .padding(.vertical, AppSpacing.s)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var transactionTable: some View {
        Table(visibleRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Datum", value: \.date) { row in
                actionMenu(for: row) {
                    Text(AppDateFormatter.weekdayDay(row.date))
                }
            }
            TableColumn("Händler", value: \.merchant) { row in
                actionMenu(for: row) {
                    HStack(spacing: AppSpacing.xs) {
                        Text(row.merchant).fontWeight(.medium)
                        if row.isManuallyAdded {
                            Text("Manuell")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
            TableColumn("Konto", value: \.account) { row in
                Text(row.account).foregroundStyle(.secondary)
            }
            TableColumn("Kategorie", value: \.category) { row in
                Text(row.category).foregroundStyle(.secondary)
            }
            TableColumn("Betrag", value: \.amount) { row in
                Text(PrivacyAwareMoney.signed(row.transaction.amount, privacy: privacyState))
                    .monospacedDigit()
                    .accessibilityLabel(
                        PrivacyAwareMoney.accessibilityLabel(
                            row.transaction.amount,
                            privacy: privacyState,
                            signed: true
                        )
                    )
            }
            TableColumn("") { row in
                Menu {
                    transactionAction(for: row)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Aktionen für \(row.merchant)")
                .help("Zuordnung zur Sammlung ändern")
            }
            .width(36)
        }
        // Im schmalen Fenster scrollt die Tabelle seitlich per Trackpad,
        // ohne dauerhaft sichtbaren Rollbalken.
        .scrollIndicators(.never, axes: .horizontal)
        .accessibilityLabel(
            displayMode == .included
                ? String(localized: "Transaktionen in der Sammlung")
                : String(localized: "Ausgeschlossene Transaktionen")
        )
        .onChange(of: displayMode) { _, _ in selection = [] }
    }

    private func actionMenu<Content: View>(
        for row: PocketTransactionRow,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content().contextMenu { transactionAction(for: row) }
    }

    @ViewBuilder
    private func transactionAction(for row: PocketTransactionRow) -> some View {
        if row.isExcluded || row.isManuallyAdded {
            Button("Automatik wiederherstellen") { onRestore(row.transaction) }
                .disabled(isMutating)
        } else {
            Button("Aus Sammlung ausschließen") { onExclude(row.transaction) }
                .disabled(isMutating)
        }
    }
}
#endif

#if os(iOS)
private struct PocketMobileDetail: View {
    let model: PocketsModel
    let collectionID: UUID
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onAddTransaction: () -> Void
    @Environment(PrivacyPresentationState.self) private var privacyState

    var body: some View {
        Group {
            if let item = model.selectedItem, item.id == collectionID {
                List {
                    Section("Summen je Währung") {
                        ForEach(PocketCurrencySummaryPresentation.rows(from: item.snapshot.currencySummaries)) { summary in
                            LabeledContent(summary.currency.rawValue) {
                                Text(PrivacyAwareMoney.decimalString(summary.netCashflow, currency: summary.currency, privacy: privacyState))
                                    .monospacedDigit()
                            }
                        }
                        Text("Globale Analysen und Budgets bleiben unverändert.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Transaktionen") {
                        ForEach(model.selectedRows) { row in
                            transactionRow(row)
                                .swipeActions {
                                    if row.isManuallyAdded {
                                        Button("Automatik") {
                                            Task { await model.restoreAutomation(for: row.transaction) }
                                        }
                                    } else {
                                        Button("Ausschließen", role: .destructive) {
                                            Task { await model.exclude(row.transaction) }
                                        }
                                    }
                                }
                        }
                        Button("Transaktion hinzufügen", action: onAddTransaction)
                    }
                    if !model.selectedExcludedRows.isEmpty {
                        Section("Ausgeschlossen") {
                            ForEach(model.selectedExcludedRows) { row in
                                transactionRow(row)
                                    .swipeActions {
                                        Button("Automatik") {
                                            Task { await model.restoreAutomation(for: row.transaction) }
                                        }
                                    }
                            }
                        }
                    }
                    Section {
                        Button("Sammlung bearbeiten", action: onEdit)
                        Button("Sammlung löschen", role: .destructive, action: onDelete)
                    }
                }
                .navigationTitle(item.collection.name)
            } else {
                LoadingStateView()
            }
        }
        .onAppear { model.selectedCollectionID = collectionID }
    }

    private func transactionRow(_ row: PocketTransactionRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(row.merchant).fontWeight(.medium)
                Text("\(AppDateFormatter.day(row.date)) · \(row.account)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if row.isManuallyAdded {
                    Label("Manuell hinzugefügt", systemImage: "hand.tap")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(PrivacyAwareMoney.signed(row.transaction.amount, privacy: privacyState))
                .monospacedDigit()
        }
    }
}
#endif

#if DEBUG
#Preview("Pockets") {
    PocketsView(dependencies: PreviewDependencies.dependencies())
        .environment(PrivacyPresentationState())
}
#endif
