import Charts
import SwiftUI

struct DashboardView: View {
    let dependencies: AppDependencies
    /// Roadmap #79: „Alle anzeigen": Navigation zur Transaktionsliste.
    var onShowAllTransactions: (() -> Void)?
    /// P2-Entflechtung: Der Verlauf/Cashflow-Klick lebt in der Analyse
    /// (`AnalyticsView.onShowTransactionsInMonth`); die Übersicht zeigt
    /// Kennzahlen, letzte Transaktionen und Review-Einstieg ohne klickbaren
    /// Verlauf. Der Callback bleibt für Hosts verfügbar, die zur Analyse
    /// auf einen Monat verlinken wollen.
    var onShowTransactionsInMonth: ((DateInterval) -> Void)?
    var onShowBudgets: (() -> Void)?
    var onShowRecurring: (() -> Void)?
    @State private var model: DashboardModel
    @Environment(PrivacyPresentationState.self) private var privacyState

    /// Eine einzige Sheet-Quelle (item-basiert) statt mehrerer
    /// isPresented-Sheets: Verhindert leere Ghost-Sheets (macOS 26)
    /// und garantiert, dass jeder Sheet-Inhalt gültige Daten hat.
    private enum ActiveSheet: Identifiable {
        case categoryDrilldown(id: UUID?, name: String, interval: DateInterval, currency: CurrencyCode)
        case addDataSource
        case addTransaction
        case reviewQueue
        case transactionDetail(Transaction.ID)

        var id: String {
            switch self {
            case .categoryDrilldown(let id, _, _, _): "drilldown-\(id?.uuidString ?? "uncategorized")"
            case .addDataSource: "add-data-source"
            case .addTransaction: "add-transaction"
            case .reviewQueue: "review"
            case .transactionDetail(let id): "txn-\(id.uuidString)"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?

    init(
        dependencies: AppDependencies,
        model: DashboardModel? = nil,
        onShowAllTransactions: (() -> Void)? = nil,
        onShowTransactionsInMonth: ((DateInterval) -> Void)? = nil,
        onShowBudgets: (() -> Void)? = nil,
        onShowRecurring: (() -> Void)? = nil
    ) {
        self.dependencies = dependencies
        self.onShowAllTransactions = onShowAllTransactions
        self.onShowTransactionsInMonth = onShowTransactionsInMonth
        self.onShowBudgets = onShowBudgets
        self.onShowRecurring = onShowRecurring
        _model = State(initialValue: model ?? DashboardModel(dependencies: dependencies))
    }

    var body: some View {
        Group {
            if model.isLoading, model.snapshot == nil {
                LoadingStateView()
            } else if let errorMessage = model.errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await model.load() }
                }
            } else if !model.hasAnyTransactions, model.hasLoaded {
                firstRunContent
                    .accessibilityIdentifier("screen-ready-dashboard")
            } else if let snapshot = model.snapshot {
                // Lade-/Fehlerzustand, Toolbar, Sheets und Routing bleiben
                // gemeinsam; alle Installationen verwenden dieselbe
                // kanonische Dashboard-Gestaltung.
                dashboardContent(snapshot) {
                    BentoDashboardContent(
                        model: model,
                        snapshot: snapshot,
                        statusHeader: AnyView(sharedStatusHeader(snapshot)),
                        onShowAllTransactions: $0,
                        onShowTransactionsInMonth: $1,
                        onOpenCategory: $2,
                        onOpenReviewQueue: $3,
                        onOpenTransaction: $4,
                        onShowBudgets: onShowBudgets,
                        onShowRecurring: onShowRecurring
                    )
                }
                .accessibilityIdentifier("screen-ready-dashboard")
            } else {
                EmptyStateView(
                    title: String(localized: "Noch keine Daten"),
                    message: String(localized: "Sobald Transaktionen vorhanden sind, erscheint hier deine Übersicht."),
                    systemImage: "chart.bar.doc.horizontal"
                )
                .accessibilityIdentifier("screen-ready-dashboard")
            }
        }
        .workspaceNavigationTitle(String(localized: "Übersicht"))
        .workspaceToolbar {
            ToolbarItemGroup {
                Button { activeSheet = .addDataSource } label: { Label("Daten hinzufügen", systemImage: "plus") }
                    .accessibilityIdentifier("dashboard-add-data")
                    .help("Bank verbinden, Datei importieren oder Transaktion erfassen")

            #if !os(macOS)
                PrivacyToggleToolbarButton()
            #endif
            }
        }
        .task(id: model.dataRevision) {
            // MacUX-Perf (Apple: <100 ms Main-Thread pro diskreter
            // Interaktion): Revisions-Stürme (Bulk-Aktionen, Import-Folgen)
            // kumulieren in EINEN Load; die Erstladung bleibt sofortig.
            if model.hasLoaded {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await model.load()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .categoryDrilldown(let id, let name, let interval, let currency):
                CategoryDrilldownSheet(
                    categoryID: id,
                    categoryName: name,
                    dateInterval: interval,
                    currency: currency,
                    dependencies: dependencies
                )
            case .addDataSource:
                AddDataSourceView(dependencies: dependencies) {
                    activeSheet = nil
                }
                #if os(macOS)
                .frame(width: 520, height: 620)
                #endif
            case .addTransaction:
                AddTransactionSheet(dependencies: dependencies) {
                    Task { await model.load() }
                }
            case .reviewQueue:
                ReviewQueueView(dependencies: model.dependenciesForReview)
                    #if os(macOS)
                    .frame(width: 720, height: 540)
                    #else
                    .presentationDetents([.large])
                    #endif
            case .transactionDetail(let txnID):
                TransactionDetailSheet(transactionID: txnID, dependencies: dependencies)
                    #if os(macOS)
                    // Kompaktes Read-Detail: kein Detent, unter macOS 26
                    // schrumpfen Detents das Sheet unter die Fix-Größe und
                    // der Inhalt schwebt zentriert.
                    .frame(width: 520, height: 620)
                    #else
                    .presentationDetents([.medium, .large])
                    #endif
            }
        }
    }

    private var firstRunContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: AppSpacing.m) {
                    Text("Willkommen").eyebrowStyle()
                    Text("Dein Monat beginnt\nmit echten Daten.")
                        .font(.system(size: 40, weight: .semibold))
                        .tracking(-1)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Verbinde eine Bank oder importiere eine Datei. FinanceTracker trennt Währungen und zeigt danach Cashflow, Kategorien und Prognose für den aktuellen Monat.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 560, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppSpacing.m) {
                            firstRunActionButtons
                        }
                        VStack(alignment: .leading, spacing: AppSpacing.m) {
                            firstRunActionButtons
                        }
                    }
                    .controlSize(.large)
                    .padding(.top, AppSpacing.m)
                }

                HStack(alignment: .top, spacing: 0) {
                    firstRunFeature("01", "Bank verbinden", "Umsätze über Enable Banking abrufen (ausschließlich lesend).")
                    Rectangle().fill(AppPalette.hairline).frame(width: 1)
                    firstRunFeature("02", "Datei importieren", "CSV-, Excel- oder PDF-Auszüge deiner Bank lokal einlesen.")
                    Rectangle().fill(AppPalette.hairline).frame(width: 1)
                    firstRunFeature("03", "Lokal & privat", "Alle Daten bleiben auf diesem Mac. Keine Zahlungen.")
                }
                .fixedSize(horizontal: false, vertical: true)
                .appSurface(.groupedContent)

                Text("Weitere Quellen lassen sich jederzeit unter „Konten & Verbindungen“ ergänzen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 56)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .workspaceCanvas()
    }

    private func firstRunFeature(_ number: String, _ title: LocalizedStringKey, _ message: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: number)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(title).font(AppTypography.sectionTitle)
            Text(message)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var firstRunActionButtons: some View {
        Button {
            activeSheet = .addDataSource
        } label: {
            Label("Datenquelle verbinden oder importieren", systemImage: "building.columns")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint("Öffnet die Auswahl für Bankverbindung und Dateiimport.")

        Button {
            activeSheet = .addTransaction
        } label: {
            Label("Transaktion manuell erfassen", systemImage: "plus.circle")
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Erfordert ein vorhandenes Konto.")
    }

    static func reviewQueueLabel(for summary: ReviewSummary) -> String {
        func pluralized(_ count: Int, singular: String, plural: String) -> String {
            count == 1 ? singular : plural
        }
        // Der wichtigste Grund steht im Klartext; weitere offene Prüfungen
        // werden mitgezählt, damit die Zahl zum Sidebar-Badge passt.
        func withRemainder(_ label: String, shown: Int) -> String {
            let remainder = summary.totalCount - shown
            return remainder > 0 ? String(localized: "\(label) · +\(remainder) weitere") : label
        }
        if summary.uncategorizedCount > 0 {
            return withRemainder(
                pluralized(
                    summary.uncategorizedCount,
                    singular: String(localized: "1 Transaktion ohne Kategorie"),
                    plural: String(localized: "\(summary.uncategorizedCount) Transaktionen ohne Kategorie")
                ),
                shown: summary.uncategorizedCount
            )
        }
        if summary.transferCandidateCount > 0 {
            return withRemainder(
                pluralized(
                    summary.transferCandidateCount,
                    singular: String(localized: "1 möglicher Transfer"),
                    plural: String(localized: "\(summary.transferCandidateCount) mögliche Transfers")
                ),
                shown: summary.transferCandidateCount
            )
        }
        if summary.unknownMerchantCount > 0 {
            return withRemainder(
                pluralized(
                    summary.unknownMerchantCount,
                    singular: String(localized: "1 unbekannter Händler"),
                    plural: String(localized: "\(summary.unknownMerchantCount) unbekannte Händler")
                ),
                shown: summary.unknownMerchantCount
            )
        }
        if summary.foreignCurrencyCount > 0 {
            return pluralized(
                summary.foreignCurrencyCount,
                singular: String(localized: "1 Fremdwährungs-Buchung"),
                plural: String(localized: "\(summary.foreignCurrencyCount) Fremdwährungs-Buchungen")
            )
        }
        return String(localized: "Nichts zu prüfen")
    }

    static func importStatusText(for batch: ImportBatch) -> String {
        let processed = batch.importedCount + batch.updatedCount
        let result = processed == 1
            ? String(localized: "1 Buchung übernommen")
            : String(localized: "\(processed) Buchungen übernommen")
        let errors = batch.failedCount > 0 ? String(localized: " · \(batch.failedCount) Fehler") : ""
        return String(localized: "Datenstand \(AppDateFormatter.day(batch.completedAt)) · \(result)\(errors)")
    }

    /// Eine dauerhafte Seitenspalte lohnt sich nur, wenn sie tatsächlich
    /// mehrere unabhängige Arbeitsbereiche bündelt.
    static func shouldUseSideRail(availableWidth: CGFloat, nextStepCount: Int) -> Bool {
        availableWidth >= 980 && nextStepCount >= 2
    }

    @ViewBuilder
    /// Status und Routing der kanonischen Übersicht werden zentral verdrahtet.
    private func dashboardContent<Content: View>(
        _ snapshot: AnalyticsSnapshot,
        @ViewBuilder build: (
            (() -> Void)?,
            ((DateInterval) -> Void)?,
            @escaping (CategoryTotal) -> Void,
            @escaping () -> Void,
            @escaping (Transaction.ID) -> Void
        ) -> Content
    ) -> some View {
        build(
            onShowAllTransactions,
            onShowTransactionsInMonth,
            openCategoryDrilldown,
            { activeSheet = .reviewQueue },
            { activeSheet = .transactionDetail($0) }
        )
    }

    /// Import-, Kurs- und Planungshinweise ergänzen die kanonische Übersicht.
    @ViewBuilder
    private func sharedStatusHeader(_ snapshot: AnalyticsSnapshot) -> some View {
        let showsFX = snapshot.convertedForeignTransactionCount > 0 || snapshot.excludedForeignTransactionCount > 0
        let hasContent = (model.lastImportBatch?.failedCount ?? 0) > 0 || showsFX || model.planningDataWarning != nil
        if hasContent {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                if let batch = model.lastImportBatch, batch.failedCount > 0 {
                    InlineNotice(
                        message: String(localized: "Der letzte Import wurde nicht vollständig übernommen."),
                        title: batch.failedCount == 1
                            ? String(localized: "1 Importfehler")
                            : String(localized: "\(batch.failedCount) Importfehler"),
                        tone: .warning
                    )
                }
                if let planningDataWarning = model.planningDataWarning {
                    InlineNotice(message: planningDataWarning, title: String(localized: "Hinweis zur Planung"), tone: .warning)
                }
                CurrencyConversionNotice(
                    snapshot: snapshot,
                    baseCurrency: model.currency,
                    fxSnapshot: model.fxSnapshot,
                    fxIsLoading: model.fxIsLoading
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("dashboard-shared-status")
        }
    }

    /// WP12 (§91): Drilldown routet die Kategorie-ID; Namen sind kein
    /// stabiler Identifier (Namenskollisionen → falscher Drilldown).
    private func openCategoryDrilldown(_ item: CategoryTotal) {
        guard let interval = model.dashboardInterval else { return }
        activeSheet = .categoryDrilldown(
            id: item.categoryID,
            name: item.name,
            interval: interval,
            currency: model.currency
        )
    }
}

struct MonthlyCashflowChart: View {
    let points: [MonthlyCashflowPoint]
    var currency: CurrencyCode = .eur
    /// MacUX-Audit: Klick auf einen Balken → Drilldown in die Transaktionen
    /// dieses Monats. Ohne Callback bleibt das Chart rein informativ.
    var onMonthTap: ((DateInterval) -> Void)?
    var showsHeading = true

    /// Hover-Zustand (Produkt-Wunsch 29.08.2026): exakte Einnahmen/Ausgaben/
    /// Netto pro Monat als Tooltip.
    @State private var hoveredPoint: MonthlyCashflowPoint?
    @State private var hoverLocation: CGPoint = .zero

    @Environment(PrivacyPresentationState.self) private var privacyState

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            if showsHeading {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cashflow")
                    .font(.title3.weight(.semibold))
                Text("Einnahmen und Ausgaben der letzten Monate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }
            cashflowChart
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cashflowChart: some View {
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Monat", point.monthStart, unit: .month),
                    y: .value("Betrag", NSDecimalNumber(decimal: point.income).doubleValue),
                    width: .ratio(0.56)
                )
                .cornerRadius(5)
                .foregroundStyle(by: .value("Art", incomeSeries))
                .opacity(hoveredPoint == nil || hoveredPoint?.id == point.id ? 1 : 0.45)

                BarMark(
                    x: .value("Monat", point.monthStart, unit: .month),
                    y: .value("Betrag", -NSDecimalNumber(decimal: point.spending).doubleValue),
                    width: .ratio(0.56)
                )
                .cornerRadius(5)
                .foregroundStyle(by: .value("Art", spendingSeries))
                .opacity(hoveredPoint == nil || hoveredPoint?.id == point.id ? 1 : 0.45)
            }
            RuleMark(y: .value("Null", 0))
                .foregroundStyle(Color.primary.opacity(0.18))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartYAxis {
            if !privacyState.hidesAmounts {
                AxisMarks(position: .trailing) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                        .foregroundStyle(Color.primary.opacity(0.1))
                    AxisValueLabel()
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartLegend(position: .top, alignment: .leading, spacing: 12)
        .chartForegroundStyleScale(domain: [incomeSeries, spendingSeries], range: [AppPalette.chartIncome, AppPalette.chartExpense])
        .chartAccessibilitySummary(ChartAccessibility.monthlyCashflowSummary(points: points, currency: currency, amountsHidden: privacyState.hidesAmounts))
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let frame = proxy.plotFrame.map { geometry[$0] } ?? CGRect(origin: .zero, size: geometry.size)
                if let hoveredPoint, let band = bandFrame(for: hoveredPoint, proxy: proxy, plotFrame: frame) {
                    Rectangle()
                        .fill(AppPalette.brand.opacity(0.07))
                        .frame(width: band.width)
                        .position(x: band.midX, y: frame.midY)
                        .allowsHitTesting(false)
                }
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            updateHover(at: location, proxy: proxy, plotFrame: frame)
                        case .ended:
                            hoveredPoint = nil
                        }
                    }
                    .onTapGesture { location in
                        guard onMonthTap != nil, !points.isEmpty else { return }
                        let plotX = location.x - frame.minX
                        guard frame.width > 0,
                              (0...frame.width).contains(plotX),
                              let tappedDate: Date = proxy.value(atX: plotX),
                              let point = Self.nearestPoint(to: tappedDate, in: points) else { return }
                        open(point)
                    }
                if let hoveredPoint {
                    tooltip(for: hoveredPoint)
                        .position(
                            x: clamp(
                                hoverLocation.x,
                                min: 90,
                                max: max(90, geometry.size.width - 90)
                            ),
                            y: clamp(
                                hoverLocation.y - 12,
                                min: 46,
                                max: max(46, geometry.size.height - 40)
                            )
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 210)
        .accessibilityRepresentation {
            VStack {
                ForEach(points) { point in
                    if onMonthTap != nil {
                        Button(accessibilityLabel(for: point)) {
                            open(point)
                        }
                    } else {
                        Text(accessibilityLabel(for: point))
                    }
                }
            }
        }
        .accessibilityHint(onMonthTap == nil ? "" : String(localized: "Balken antippen, um die Transaktionen des Monats zu öffnen."))
    }

    /// Serien-/Legendenbeschriftungen; Domain der Farbskala und Werte der
    /// Marks müssen identisch sein.
    private var incomeSeries: String { String(localized: "Einnahmen") }
    private var spendingSeries: String { String(localized: "Ausgaben") }

    // MARK: - Hover

    private func updateHover(at location: CGPoint, proxy: ChartProxy, plotFrame: CGRect) {
        let plotX = location.x - plotFrame.minX
        guard plotFrame.width > 0, (0...plotFrame.width).contains(plotX),
              let tappedDate: Date = proxy.value(atX: plotX),
              let point = Self.nearestPoint(to: tappedDate, in: points) else {
            hoveredPoint = nil
            return
        }
        hoverLocation = location
        hoveredPoint = point
    }

    /// Spaltenband für den gehoverten Monat (x-Positionen von Monatsstart
    /// bis Folgemonat), dient der visuellen Hover-Hervorhebung.
    private func bandFrame(
        for point: MonthlyCashflowPoint,
        proxy: ChartProxy,
        plotFrame: CGRect
    ) -> CGRect? {
        guard let startX = proxy.position(forX: point.monthStart) else { return nil }
        guard let nextMonth = Calendar.current.date(byAdding: .month, value: 1, to: point.monthStart),
              let endX = proxy.position(forX: nextMonth) else {
            return CGRect(x: startX - 10, y: 0, width: 20, height: plotFrame.height)
        }
        let width = max(12, abs(endX - startX))
        return CGRect(x: startX, y: 0, width: width, height: plotFrame.height)
    }

    private func tooltip(for point: MonthlyCashflowPoint) -> some View {
        let net = point.income - point.spending
        return ChartHoverTooltip(
            title: AppDateFormatter.monthYear(point.monthStart),
            rows: [
                ChartHoverTooltip.Row(label: incomeSeries, value: amount(point.income), color: AppPalette.chartIncome),
                ChartHoverTooltip.Row(label: spendingSeries, value: amount(point.spending), color: AppPalette.chartExpense),
                ChartHoverTooltip.Row(label: String(localized: "Netto"), value: amount(net), color: nil)
            ]
        )
    }

    private func amount(_ value: Decimal) -> String {
        PrivacyAwareMoney.decimalString(value, currency: currency, privacy: privacyState)
    }

    /// Nächster Datenpunkt zu einem Datum (reine Funktion, getestet).
    /// `nonisolated`: Mapping-Logik ohne UI-Bezug, von überall aufrufbar.
    nonisolated static func nearestPoint(to date: Date, in points: [MonthlyCashflowPoint]) -> MonthlyCashflowPoint? {
        points.min {
            abs($0.monthStart.timeIntervalSince(date)) < abs($1.monthStart.timeIntervalSince(date))
        }
    }

    private func open(_ point: MonthlyCashflowPoint) {
        guard let interval = Self.monthInterval(containing: point.monthStart) else { return }
        onMonthTap?(interval)
    }

    private func accessibilityLabel(for point: MonthlyCashflowPoint) -> String {
        let income = PrivacyAwareMoney.accessibilityLabel(point.income, currency: currency, privacy: privacyState)
        let spending = PrivacyAwareMoney.accessibilityLabel(point.spending, currency: currency, privacy: privacyState)
        return String(localized: "\(AppDateFormatter.monthYear(point.monthStart)): Einnahmen \(income), Ausgaben \(spending)")
    }

    nonisolated static func monthInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), upper)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        DashboardView(dependencies: PreviewDependencies.dependencies())
    }
}
#endif
