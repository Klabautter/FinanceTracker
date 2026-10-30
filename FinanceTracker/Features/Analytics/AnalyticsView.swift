import Charts
import SwiftUI

struct AnalyticsFilterControls: View {
    @Bindable var model: AnalyticsModel

    var body: some View {
        Picker("Zeitraum", selection: $model.range) {
            ForEach(AnalyticsModel.DateRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .accessibilityLabel("Zeitraum für die Analyse")
        .onChange(of: model.range) { _, _ in
            model.filtersChanged()
        }

        Menu {
            ForEach(model.availableAccounts) { account in
                Button {
                    toggle(&model.filterAccountIDs, account.id)
                    model.filtersChanged()
                } label: {
                    Label(
                        account.name,
                        systemImage: model.filterAccountIDs.contains(account.id) ? "checkmark" : "circle"
                    )
                }
            }
        } label: {
            Label(
                model.filterAccountIDs.isEmpty
                    ? String(localized: "Konten")
                    : String(localized: "Konten (\(model.filterAccountIDs.count))"),
                systemImage: "building.columns"
            )
        }
        .accessibilityLabel("Kontenfilter")
        .accessibilityValue(model.filterAccountIDs.isEmpty ? Text("Alle Konten") : Text("\(model.filterAccountIDs.count) ausgewählt"))

        Menu {
            ForEach(model.parentCategoriesForFilter) { category in
                Button {
                    toggle(&model.filterCategoryIDs, category.id)
                    model.filtersChanged()
                } label: {
                    Label(
                        category.name,
                        systemImage: model.filterCategoryIDs.contains(category.id) ? "checkmark" : "circle"
                    )
                }
            }
        } label: {
            Label(
                model.filterCategoryIDs.isEmpty
                    ? String(localized: "Kategorien")
                    : String(localized: "Kategorien (\(model.filterCategoryIDs.count))"),
                systemImage: "square.grid.2x2"
            )
        }
        .accessibilityLabel("Kategorienfilter")
        .accessibilityValue(model.filterCategoryIDs.isEmpty ? Text("Alle Kategorien") : Text("\(model.filterCategoryIDs.count) ausgewählt"))

        Menu {
            Button("Alle Quellen") {
                model.filterSource = nil
                model.filtersChanged()
            }
            Divider()
            ForEach(TransactionSource.allCases, id: \.self) { source in
                Button {
                    model.filterSource = source
                    model.filtersChanged()
                } label: {
                    Label(source.displayName, systemImage: model.filterSource == source ? "checkmark" : "circle")
                }
            }
        } label: {
            Label(model.filterSource?.displayName ?? String(localized: "Quelle"), systemImage: "tray.and.arrow.down")
        }
        .accessibilityLabel("Quellenfilter")
        .accessibilityValue(model.filterSource?.displayName ?? String(localized: "Alle Quellen"))

        if model.activeFilterCount > 0 || model.range != .last12Months {
            Button {
                model.resetFilters()
            } label: {
                Label("Zurücksetzen", systemImage: "xmark.circle")
            }
        }
    }

    private func toggle(_ set: inout Set<UUID>, _ id: UUID) {
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
    }
}

struct AnalyticsView: View {
    @State private var model: AnalyticsModel
    @State private var showsFilterSheet = false

    @State private var showsPercentages = false
    @State private var merchantDetail: MerchantSelection?
    @State private var categoryDetail: CategoryTotal?
    @Environment(PrivacyPresentationState.self) private var privacyState

    /// WP24: Ausstehende Palette-Route (Kategorie → Analytics-Filter).
    var pendingRoute: Binding<PaletteRoute?>
    /// MacUX-Audit (Redundanz): Querverweis zu Fixkosten & Abos, als
    /// Callback statt NavigationLink (macOS-Detail hat keinen Stack).
    var onOpenRecurring: (() -> Void)?
    /// Monats-Drilldown übernimmt den vollständigen Analysefilter.
    var onShowTransactionsInMonth: ((AnalyticsScope) -> Void)?

    init(
        dependencies: AppDependencies,
        pendingRoute: Binding<PaletteRoute?>,
        onOpenRecurring: (() -> Void)? = nil,
        onShowTransactionsInMonth: ((AnalyticsScope) -> Void)? = nil
    ) {
        _model = State(initialValue: AnalyticsModel(dependencies: dependencies))
        self.pendingRoute = pendingRoute
        self.onOpenRecurring = onOpenRecurring
        self.onShowTransactionsInMonth = onShowTransactionsInMonth
    }

    var body: some View {
        Group {
            #if os(macOS)
            VStack(spacing: 0) {
                    PageHeader(
                        String(localized: "Analyse"),
                        subtitle: model.scope?.summary ?? String(localized: "Deine Einnahmen und Ausgaben im Überblick"),
                        eyebrow: String(localized: "Alltag")
                    ) {
                        Button { showsFilterSheet = true } label: {
                            Label(
                                model.activeFilterCount == 0
                                    ? String(localized: "Zeitraum & Filter")
                                    : String(localized: "Zeitraum & Filter (\(model.activeFilterCount))"),
                                systemImage: "line.3.horizontal.decrease"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, AppLayout.pageHorizontalPadding)
                    .padding(.top, AppSpacing.xl)
                    .padding(.bottom, AppSpacing.m)
                    .frame(maxWidth: AppLayout.summaryMaximumWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .workspaceCanvas()
                content
            }
            #else
            content
                .workspaceToolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showsFilterSheet = true
                        } label: {
                            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .overlay(alignment: .topTrailing) {
                            if model.activeFilterCount > 0 || model.range != .last12Months {
                                Circle().fill(Color.accentColor).frame(width: 8, height: 8).offset(x: 6, y: -2)
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        PrivacyToggleToolbarButton()
                            .help(privacyState.hidesAmounts ? Text("Beträge anzeigen") : Text("Beträge verbergen"))
                    }
                }
            #endif
        }
        .background(AppPalette.canvas)
        .workspaceNavigationTitle(String(localized: "Analyse"))
        .task(id: model.dataRevision) {
            await model.load()
            await consumePendingRoute()
        }
        .onChange(of: pendingRoute.wrappedValue) { _, route in
            // WP24/MacUX-Perf: Deep-Link bei bereits sichtbarem Screen.
            guard route != nil else { return }
            Task { await consumePendingRoute() }
        }
        .sheet(isPresented: $showsFilterSheet) {
            AdaptiveSheet(title: String(localized: "Analyse filtern")) {
                Form {
                    Section("Filter") {
                        @Bindable var model = model
                        AnalyticsFilterControls(model: model)
                    }
                }
                .financeFormStyle()
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { showsFilterSheet = false }
                    }
                }
            }
            #if os(macOS)
            .frame(width: 460, height: 320)
            #else
            // Detents nur auf iOS: unter macOS 26 schrumpfen sie das
            // Sheet unter die Fix-Größe (Inhalt schwebt zentriert).
            .presentationDetents([.medium])
            #endif
        }
    }

    /// WP24: Deep-Link-Konsum: Kategorie als Analytics-Filter.
    private func consumePendingRoute() async {
        guard case .category(let categoryID) = pendingRoute.wrappedValue else { return }
        pendingRoute.wrappedValue = nil
        model.filterCategoryIDs = Set([categoryID])
        model.filtersChanged()
    }

    private func content(for snapshot: AnalyticsSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.l) {
                CurrencyConversionNotice(
                    snapshot: snapshot,
                    baseCurrency: model.currency,
                    fxSnapshot: model.fxSnapshot,
                    fxIsLoading: model.fxIsLoading
                )
                summaryCards(for: snapshot)
                if !model.displayedMonthlyPoints.isEmpty {
                    PageSection(
                        String(localized: "Cashflow"),
                        subtitle: String(localized: "Einnahmen und Ausgaben pro Monat · Monat anklicken für Details")
                    ) {
                        MonthlyCashflowChart(
                            points: model.displayedMonthlyPoints,
                            currency: model.currency,
                            onMonthTap: { interval in
                                guard let scope = model.scope else { return }
                                onShowTransactionsInMonth?(scope.inMonth(interval))
                            },
                            showsHeading: false
                        )
                    }
                }
                categoryPie
                topMerchantsSection()
            }
            .padding(.horizontal, AppLayout.pageHorizontalPadding)
            .padding(.bottom, AppSpacing.xl)
            .frame(maxWidth: AppLayout.summaryMaximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .workspaceCanvas()
        .refreshable { await model.load() }
    }

    private var content: some View {
        Group {
            if model.isLoading, model.snapshot == nil {
                LoadingStateView(label: String(localized: "Analyse für den gewählten Bereich laden…"))
            } else if let errorMessage = model.errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await model.load() }
                }
            } else if let snapshot = model.snapshot, snapshot.transactionCount == 0 {
                EmptyStateView(
                    title: String(localized: "Keine Transaktionen im Zeitraum"),
                    message: String(localized: "Für den gewählten Zeitraum und Filter gibt es keine Transaktionen. Passe „Zeitraum & Filter“ an oder importiere Daten."),
                    systemImage: "chart.pie.fill"
                ) {
                    Button("Zeitraum & Filter") { showsFilterSheet = true }
                        .buttonStyle(.bordered)
                }
                .accessibilityIdentifier("screen-ready-analytics")
            } else if let snapshot = model.snapshot {
                content(for: snapshot)
                    .accessibilityIdentifier("screen-ready-analytics")
            } else {
                EmptyStateView(
                    title: String(localized: "Keine Daten"),
                    message: String(localized: "Sobald Transaktionen vorhanden sind, erscheint hier deine Analyse."),
                    systemImage: "chart.pie"
                )
                .accessibilityIdentifier("screen-ready-analytics")
            }
        }
    }

    /// Kompakte Kennzahl-Zeile (Roadmap #93) statt drei gleichwertiger Cards.
    private func summaryCards(for snapshot: AnalyticsSnapshot) -> some View {
        MetricStrip(metrics: summaryMetrics(for: snapshot))
    }

    private func summaryMetrics(for snapshot: AnalyticsSnapshot) -> [MetricStripItem] {
        var metrics = baseSummaryMetrics(for: snapshot)
        // Cashback steht als eigene Kennzahl daneben, er ist in keiner der
        // drei Summen verrechnet.
        metrics.append(CashbackPresentation.metric(snapshot.cashbackTotals, baseCurrency: model.currency, privacy: privacyState))
        return metrics
    }

    private func baseSummaryMetrics(for snapshot: AnalyticsSnapshot) -> [MetricStripItem] {
        [
            MetricStripItem(label: String(localized: "Einnahmen"), value: PrivacyAwareMoney.signedTotal(snapshot.totalIncome, kind: .income, currency: model.currency, privacy: privacyState), tone: snapshot.totalIncome == 0 ? .neutral : .positive, accessibilityValue: accessibleAmount(snapshot.totalIncome)),
            MetricStripItem(label: String(localized: "Ausgaben"), value: PrivacyAwareMoney.signedTotal(snapshot.totalSpending, kind: .expense, currency: model.currency, privacy: privacyState), caption: model.spendingDeltaText ?? String(localized: "netto nach Erstattungen"), tone: snapshot.totalSpending == 0 ? .neutral : .critical, accessibilityValue: accessibleAmount(snapshot.totalSpending)),
            MetricStripItem(label: String(localized: "Saldo"), value: PrivacyAwareMoney.signedTotal(snapshot.netCashflow, kind: .balance, currency: model.currency, privacy: privacyState), caption: String(localized: "Einnahmen − Ausgaben"), tone: snapshot.netCashflow < 0 ? .critical : (snapshot.netCashflow == 0 ? .neutral : .positive), accessibilityValue: accessibleAmount(snapshot.netCashflow))
        ]
    }

    private var categoryPie: some View {
        PageSection(
            String(localized: "Ausgaben nach Kategorie"),
            subtitle: String(localized: "Bruttoausgaben vor Erstattungen und Cashback")
        ) {
            categoryPieContent
        } accessory: {
                // Roadmap #89: €/%-Toggle
                Picker("Anzeige", selection: $showsPercentages) {
                    Text(model.currency.rawValue).tag(false)
                    Text("%").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .accessibilityLabel("Kategorie-Werte anzeigen")
                .accessibilityValue(showsPercentages ? Text("Anteil in Prozent") : Text("Betrag in \(model.currency.rawValue)"))
        }
    }

    @ViewBuilder
    private var categoryPieContent: some View {
            if model.categoryPieItems.isEmpty {
                EmptyStateView(
                    title: String(localized: "Keine Ausgaben"),
                    message: String(localized: "In diesem Zeitraum gab es keine Ausgaben."),
                    systemImage: "chart.pie"
                )
                .frame(height: 200)
            } else {
                // Produkt-Wunsch 29.08.2026: Donut-Pie mit Hover-Tooltip
                // (exakter Betrag + Anteil) neben der Rangliste.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppSpacing.xl) {
                        pie
                        categoryRanking
                    }
                    VStack(alignment: .leading, spacing: AppSpacing.l) {
                        pie
                            .frame(maxWidth: .infinity)
                        categoryRanking
                    }
                }
            }
    }

    private var pie: some View {
        CategoryPieChart(
            slices: model.categoryPieItems.map { item in
                CategoryPieSlice(
                    id: item.id,
                    name: item.name,
                    amount: item.amount,
                    color: categoryColor(for: item)
                )
            },
            currency: model.currency
        )
        .frame(width: 220, height: 220)

    }

    private var categoryTotal: Decimal {
        model.categoryPieItems.reduce(into: Decimal(0)) { $0 += $1.amount }
    }

    private var categoryRanking: some View {
        let total = categoryTotal
        let maximum = model.categoryPieItems.map(\.amount).max() ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.categoryPieItems.enumerated()), id: \.element.id) { index, item in
                Button {
                    categoryDetail = item
                } label: {
                  VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: AppSpacing.s) {
                        IconTile(systemName: categoryIcon(for: item), color: categoryColor(for: item), size: 26)
                        Text(item.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(showsPercentages ? percentText(item.amount, total: total) : amountText(item.amount))
                            .font(AppTypography.amount.monospacedDigit())
                            .frame(minWidth: 92, alignment: .trailing)
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.07))
                            Capsule()
                                .fill(categoryColor(for: item))
                                .frame(width: max(4, proxy.size.width * ratio(item.amount, maximum: maximum)))
                        }
                    }
                    .frame(height: 4)
                    .padding(.leading, 34)
                    .accessibilityHidden(true)
                }
                  .padding(.vertical, 8)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Kein `.accessibilityElement(children: .ignore)`: Das ersetzt
                // den Button durch ein rollenloses Element ohne Auslöse-Aktion.
                .accessibilityLabel(categoryAccessibilityLabel(item, rank: index + 1, total: total))
                .accessibilityHint("Öffnet die Buchungen dieser Kategorie")
            }
        }
        .accessibilityElement(children: .contain)
        .sheet(item: $categoryDetail) { item in
            if let scope = model.scope, let interval = scope.query.dateInterval {
                CategoryDrilldownSheet(categoryID: item.categoryID, categoryName: item.name,
                                       dateInterval: interval, currency: model.currency,
                                       dependencies: model.dependencies, scope: scope)
            }
        }
    }

    private func categoryColor(for item: CategoryTotal) -> Color {
        guard let categoryID = item.categoryID,
              let category = model.availableCategories.first(where: { $0.id == categoryID }) else {
            return .gray
        }
        return category.colorToken.color
    }

    private func categoryIcon(for item: CategoryTotal) -> String {
        if item.isRemainder { return "square.grid.2x2" }
        guard let categoryID = item.categoryID,
              let category = model.availableCategories.first(where: { $0.id == categoryID }) else {
            return "questionmark"
        }
        return category.systemIconName
    }

    private func ratio(_ amount: Decimal, maximum: Decimal) -> Double {
        guard maximum > 0 else { return 0 }
        return NSDecimalNumber(decimal: amount / maximum).doubleValue
    }

    private func categoryAccessibilityLabel(_ item: CategoryTotal, rank: Int, total: Decimal) -> String {
        let value = showsPercentages
            ? percentText(item.amount, total: total)
            : PrivacyAwareMoney.accessibilityLabel(item.amount, currency: model.currency, privacy: privacyState)
        return String(localized: "Rang \(rank), \(item.name), \(value)")
    }

    private func percentText(_ amount: Decimal, total: Decimal) -> String {
        guard total > 0 else { return "0 %" }
        let percent = NSDecimalNumber(decimal: (amount / total) * Decimal(100)).rounding(accordingToBehavior:
            NSDecimalNumberHandler(roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false)
        ).intValue
        return "\(percent) %"
    }

    /// Roadmap #90: Merchant-Klick öffnet das Merchant-Detail.
    private func topMerchantsSection() -> some View {
        PageSection(
            String(localized: "Top-Händler"),
            subtitle: String(localized: "Wo im gewählten Zeitraum das meiste Geld hinging")
        ) {
            let merchants = model.topMerchants
            if merchants.isEmpty {
                EmptyStateView(
                    title: String(localized: "Keine Händler"),
                    message: String(localized: "In diesem Zeitraum gab es keine Ausgaben."),
                    systemImage: "cart"
                )
                .frame(height: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(merchants.enumerated()), id: \.element.id) { index, merchant in
                        Button {
                            guard let scope = model.scope else { return }
                            merchantDetail = MerchantSelection(name: merchant.name, scope: scope)
                        } label: {
                            HStack(spacing: AppSpacing.m) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill(Color.primary.opacity(0.06)))
                                Text(merchant.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(amountText(merchant.amount))
                                    .font(AppTypography.amount)
                                    .monospacedDigit()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 7)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowHighlightButtonStyle())
                        .accessibilityLabel("Händler \(merchant.name), \(PrivacyAwareMoney.accessibilityLabel(merchant.amount, currency: model.currency, privacy: privacyState)), Detail öffnen")
                    }
                }
            }
        }
        .sheet(item: $merchantDetail) { selection in
            MerchantDetailSheet(
                merchantName: selection.name,
                scope: selection.scope,
                dependencies: model.dependencies
            )
                #if os(macOS)
                .frame(width: 560, height: 520)
                #endif
        }
    }

    private func amountText(_ amount: Decimal) -> String {
        return PrivacyAwareMoney.decimalString(amount, currency: model.currency, privacy: privacyState)
    }

    private func accessibleAmount(_ amount: Decimal) -> String {
        PrivacyAwareMoney.accessibilityLabel(amount, currency: model.currency, privacy: privacyState)
    }
}

/// Identifizierbare Merchant-Auswahl für das Detail-Sheet.
struct MerchantSelection: Identifiable {
    let id = UUID()
    let name: String
    let scope: AnalyticsScope
}
