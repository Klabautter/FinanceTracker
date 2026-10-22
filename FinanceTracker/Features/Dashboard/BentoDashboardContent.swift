import Charts
import SwiftUI

/// Übersicht: Ausgabenverlauf vs. Vormonat als Herzstück, darunter klare
/// Plus/Minus-Kennzahlen, Planung, Budgets, Termine, Kategorien und Buchungen.
struct BentoDashboardContent: View {
    let model: DashboardModel
    let snapshot: AnalyticsSnapshot
    /// Import-/Kurs-/Planungshinweise aus dem Host (optional).
    var statusHeader: AnyView?
    var onShowAllTransactions: (() -> Void)?
    var onShowTransactionsInMonth: ((DateInterval) -> Void)?
    let onOpenCategory: (CategoryTotal) -> Void
    let onOpenReviewQueue: () -> Void
    let onOpenTransaction: (Transaction.ID) -> Void
    @Environment(PrivacyPresentationState.self) private var privacyState
    @State private var showsCalculation = false
    var scrollsContent = true
    var onShowBudgets: (() -> Void)?
    var onShowRecurring: (() -> Void)?

    var body: some View {
        if scrollsContent {
            ScrollView { stack }
                .refreshable { await model.load() }
                .workspaceCanvas()
        } else {
            stack
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: AppSpacing.l) {
            PageHeader(
                monthTitle,
                subtitle: String(localized: "Alle Konten · Beträge in \(model.currency.rawValue)"),
                eyebrow: String(localized: "Übersicht")
            ) {
                HStack(spacing: AppSpacing.m) {
                    monthSwitcher
                    if model.reviewSummary.totalCount > 0 {
                        reviewButton
                    }
                }
            }
            .padding(.bottom, AppSpacing.xs)
            if let statusHeader {
                statusHeader
            }
            paceHero
            MetricStrip(metrics: headlineMetrics)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppSpacing.l) {
                    VStack(alignment: .leading, spacing: AppSpacing.l) {
                        historySection
                        ledgerTile
                    }
                    .frame(minWidth: 460, maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: AppSpacing.l) {
                        planningSection
                        if !model.budgetProgresses.isEmpty { budgetSection }
                        if !model.upcomingOccurrences.isEmpty { upcomingSection }
                        allocationSection
                    }
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 400, alignment: .topLeading)
                }
                .frame(minWidth: 800)

                VStack(alignment: .leading, spacing: AppSpacing.l) {
                    planningSection
                    historySection
                    if !model.budgetProgresses.isEmpty { budgetSection }
                    if !model.upcomingOccurrences.isEmpty { upcomingSection }
                    allocationSection
                    ledgerTile
                }
            }
        }
        .padding(.horizontal, AppLayout.pageHorizontalPadding)
        .padding(.vertical, AppLayout.pageVerticalPadding)
        .frame(maxWidth: AppLayout.summaryMaximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .workspaceCanvas()
    }

    private var monthTitle: String {
        guard let interval = model.dashboardInterval else { return String(localized: "Dein Monat") }
        return AppDateFormatter.monthYear(interval.start)
    }

    /// Monatswechsel: zurück, vor (nur bis zum laufenden Monat) und Sprung
    /// zum aktuellen Monat.
    private var monthSwitcher: some View {
        HStack(spacing: AppSpacing.xs) {
            if !model.isShowingCurrentMonth {
                Button("Aktueller Monat") {
                    Task { await model.showCurrentMonth() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("dashboard-month-current")
            }
            Button {
                Task { await model.showPreviousMonth() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .help("Vorheriger Monat")
            .accessibilityLabel("Vorheriger Monat")
            .accessibilityIdentifier("dashboard-month-previous")
            Button {
                Task { await model.showNextMonth() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.bordered)
            .disabled(model.isShowingCurrentMonth)
            .help("Nächster Monat")
            .accessibilityLabel("Nächster Monat")
            .accessibilityIdentifier("dashboard-month-next")
        }
    }

    private var reviewButton: some View {
        Button(action: onOpenReviewQueue) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(AppPalette.warning)
                Text(DashboardView.reviewQueueLabel(for: model.reviewSummary))
            }
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(DashboardView.reviewQueueLabel(for: model.reviewSummary))
        .accessibilityIdentifier("dashboard-review-queue")
        .accessibilityHint("Öffnet die Prüfliste zum Kategorisieren und Bestätigen.")
    }

    // MARK: - Hero: Ausgabenverlauf

    private var paceHero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: AppSpacing.xl) {
                paceSummary.frame(width: 270, alignment: .leading)
                paceChart
            }
            .frame(minWidth: 640)
            VStack(alignment: .leading, spacing: AppSpacing.l) {
                paceSummary
                paceChart
            }
        }
        .financeCard(padding: 22)
    }

    private var paceSummary: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            (model.isShowingCurrentMonth ? Text("Ausgaben bisher") : Text("Ausgaben")).eyebrowStyle()
            Text(amountString(model.spendingPace?.currentTotal ?? snapshot.totalSpending))
                .font(AppTypography.heroMetric)
                .tracking(-0.8)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            // Ohne Ausgaben in beiden Monaten gibt es nichts zu vergleichen.
            if let pace = model.spendingPace, let delta = pace.deltaToPrevious,
               !(delta == 0 && pace.currentTotal == 0) {
                paceDeltaChip(delta)
            }
            Spacer(minLength: AppSpacing.s)
            HStack(spacing: AppSpacing.l) {
                legendItem(color: AppPalette.brand, dashed: false, title: model.isShowingCurrentMonth ? String(localized: "Dieser Monat") : monthTitle)
                legendItem(color: .secondary, dashed: true, title: String(localized: "Vormonat"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func paceDeltaChip(_ delta: Decimal) -> some View {
        let isMore = delta > 0
        let tone: AppTone = delta == 0 ? .neutral : (isMore ? .critical : .positive)
        let text: String
        if delta == 0 {
            text = String(localized: "Gleich viel wie im Vormonat")
        } else {
            let amount = amountString(abs(delta))
            text = isMore
                ? String(localized: "\(amount) mehr als im Vormonat")
                : String(localized: "\(amount) weniger als im Vormonat")
        }
        let color = tone == .neutral ? Color.secondary : tone.foregroundColor
        return HStack(spacing: 5) {
            Image(systemName: delta == 0 ? "equal" : (isMore ? "arrow.up.right" : "arrow.down.right"))
                .font(.caption.weight(.bold))
            Text(text)
                .font(.callout.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
        .accessibilityLabel(model.isShowingCurrentMonth ? String(localized: "\(text) bis zum heutigen Tag") : text)
    }

    private func legendItem(color: Color, dashed: Bool, title: String) -> some View {
        HStack(spacing: 6) {
            // Eine echte Linie statt eines umrandeten Kapsel-Umrisses: Dessen
            // Ober- und Unterkante ergaben gestrichelt kleine Kringel.
            Path { path in
                path.move(to: CGPoint(x: 1, y: 1))
                path.addLine(to: CGPoint(x: 17, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: dashed ? .butt : .round, dash: dashed ? [4, 3] : []))
            .frame(width: 18, height: 2)
            Text(title)
        }
    }

    @ViewBuilder
    private var paceChart: some View {
        if let pace = model.spendingPace, !pace.current.isEmpty {
            Chart {
                ForEach(pace.previous) { point in
                    LineMark(
                        x: .value("Datum", point.day),
                        y: .value("Betrag", double(point.cumulative)),
                        series: .value("Reihe", "Vormonat")
                    )
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .interpolationMethod(.monotone)
                }
                ForEach(pace.current) { point in
                    AreaMark(
                        x: .value("Datum", point.day),
                        y: .value("Betrag", double(point.cumulative))
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [AppPalette.brand.opacity(0.22), AppPalette.brand.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Datum", point.day),
                        y: .value("Betrag", double(point.cumulative)),
                        series: .value("Reihe", "Dieser Monat")
                    )
                    .foregroundStyle(AppPalette.brand)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
                }
                if let last = pace.current.last {
                    PointMark(x: .value("Datum", last.day), y: .value("Betrag", double(last.cumulative)))
                        .foregroundStyle(AppPalette.brand)
                        .symbolSize(60)
                }
            }
            .chartXScale(domain: 1...max(pace.daysInCurrentMonth, pace.previous.count, 2))
            .chartXAxis {
                AxisMarks(values: [1, 8, 15, 22, 29]) { value in
                    AxisValueLabel {
                        if let day = value.as(Int.self) { Text("\(day).") }
                    }
                    .foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis {
                if !privacyState.hidesAmounts {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                            .foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel().foregroundStyle(Color.secondary)
                    }
                }
            }
            .frame(minHeight: 170, maxHeight: 190)
            .accessibilityLabel("Kumulierte Ausgaben dieses Monats im Vergleich zum Vormonat")
        } else {
            Text("Noch keine Ausgaben in diesem Monat.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 170)
        }
    }

    // MARK: - Kennzahlen

    private var headlineMetrics: [MetricStripItem] {
        var metrics = [
            MetricStripItem(label: String(localized: "Einnahmen"), value: signedAmount(snapshot.totalIncome, sign: "+"), tone: snapshot.totalIncome == 0 ? .neutral : .positive),
            MetricStripItem(label: String(localized: "Ausgaben"), value: signedAmount(snapshot.totalSpending, sign: "−"), caption: String(localized: "netto nach Erstattungen"), tone: snapshot.totalSpending == 0 ? .neutral : .critical),
            MetricStripItem(
                label: String(localized: "Saldo"),
                value: signedAmount(abs(snapshot.netCashflow), sign: snapshot.netCashflow < 0 ? "−" : "+"),
                caption: String(localized: "Einnahmen − Ausgaben"),
                tone: snapshot.netCashflow < 0 ? .critical : (snapshot.netCashflow == 0 ? .neutral : .positive)
            )
        ]
        // Cashback des Monats: eigene Kennzahl, nicht in Ausgaben/Saldo verrechnet.
        metrics.append(CashbackPresentation.metric(snapshot.cashbackTotals, baseCurrency: model.currency, privacy: privacyState))
        if snapshot.pendingCount > 0 {
            metrics.append(MetricStripItem(
                label: String(localized: "Vorgemerkt"),
                value: amountString(snapshot.pendingAmount),
                caption: snapshot.pendingCount == 1
                    ? String(localized: "1 offene Buchung")
                    : String(localized: "\(snapshot.pendingCount) offene Buchungen"),
                tone: .warning
            ))
        }
        return metrics
    }

    private func signedAmount(_ value: Decimal, sign: String) -> String {
        let text = amountString(value)
        guard !privacyState.hidesAmounts, value != 0 else { return text }
        return sign + text
    }

    // MARK: - Planung

    @ViewBuilder
    private var planningSection: some View {
        if let forecast = model.forecast, forecast.confidence != .low {
            PageSection(String(localized: "Verfügbar bis Monatsende"), subtitle: String(localized: "Prognose · kein Kontostand")) {
                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    Text(amountString(forecast.availableAmount))
                        .font(AppTypography.largeMetric)
                        .monospacedDigit()
                        .foregroundStyle(forecast.availableAmount < 0 ? AppPalette.critical : AppPalette.positive)
                    Text(forecastCaption(forecast))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(isExpanded: $showsCalculation) {
                        VStack(spacing: 6) {
                            calculationRow("Gebuchte Einnahmen", forecast.realizedIncome)
                            calculationRow("Erwartete Einnahmen", forecast.expectedIncome)
                            calculationRow("Bereits verbraucht", -(forecast.realizedFixedCosts + forecast.realizedVariableSpending))
                            calculationRow("Offene Fixkosten", -forecast.expectedFixedCosts)
                            calculationRow("Reservierter Budgetrest", -forecast.remainingBudgetReservation)
                            if forecast.plannedSavings != 0 {
                                calculationRow("Geplantes Sparen", -forecast.plannedSavings)
                            }
                            Divider()
                            calculationRow("Planungsrest", forecast.availableAmount)
                                .fontWeight(.semibold)
                        }
                        .padding(.top, AppSpacing.s)
                    } label: {
                        Text("So wird gerechnet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func forecastCaption(_ forecast: ForecastSnapshot) -> String {
        let days = forecast.daysRemaining == 1
            ? String(localized: "noch \(forecast.daysRemaining) Tag")
            : String(localized: "noch \(forecast.daysRemaining) Tage")
        if forecast.availableAmount > 0 {
            return String(localized: "≈ \(amountString(forecast.availablePerDay)) pro Tag · \(days)")
        }
        return String(localized: "Geplante Ausgaben übersteigen den Rahmen · \(days)")
    }

    private func calculationRow(_ label: LocalizedStringKey, _ amount: Decimal) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: AppSpacing.m)
            Text(amountString(amount))
                .monospacedDigit()
                .foregroundStyle(amount < 0 ? AppPalette.critical : (amount > 0 ? AppPalette.positive : Color.primary))
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Budgets

    private var budgetSection: some View {
        PageSection(String(localized: "Budgets"), subtitle: String(localized: "Verbrauch im jeweiligen Zeitraum")) {
            VStack(alignment: .leading, spacing: AppSpacing.l) {
                ForEach(model.attentionBudgets) { progress in
                    budgetRow(progress)
                }
            }
        } accessory: {
            if let onShowBudgets {
                SectionLinkButton(String(localized: "Alle"), action: onShowBudgets)
            }
        }
    }

    private func budgetRow(_ progress: BudgetProgress) -> some View {
        let tone: AppTone = progress.isOverBudget ? .critical : (progress.fraction >= 0.85 ? .warning : .positive)
        let categoryColor = progress.budget.categoryIDs.first.flatMap { model.categoriesByID[$0]?.colorToken.color } ?? AppPalette.brand
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: AppSpacing.s) {
                IconTile(systemName: progress.budget.systemIconName, color: categoryColor, size: 26)
                Text(progress.budget.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: AppSpacing.s)
                Text(Self.percentText(spent: progress.spent, limit: progress.effectiveLimit))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tone.foregroundColor)
            }
            FinanceProgressBar(fraction: progress.fraction, tone: tone, height: 6)
                .accessibilityLabel("Budgetverbrauch \(progress.budget.name)")
            HStack {
                Text("\(money(progress.spent, currency: progress.currency)) von \(money(progress.effectiveLimit, currency: progress.currency))")
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppSpacing.s)
                if progress.isOverBudget {
                    Text("\(money(progress.spent - progress.effectiveLimit, currency: progress.currency)) drüber")
                        .fontWeight(.medium)
                        .foregroundStyle(AppPalette.critical)
                } else {
                    Text("\(money(progress.effectiveLimit - progress.spent, currency: progress.currency)) übrig")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .monospacedDigit()
            if !progress.excludedCurrencies.isEmpty {
                Text("Ohne Kurs: \(progress.excludedCurrencies.map(\.rawValue).sorted().joined(separator: ", "))")
                    .font(.caption).foregroundStyle(AppPalette.warning)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Anstehend

    private var upcomingSection: some View {
        PageSection(String(localized: "Anstehend"), subtitle: String(localized: "Nächste 30 Tage")) {
            VStack(spacing: AppSpacing.s) {
                ForEach(model.upcomingOccurrences.prefix(4)) { occurrence in
                    let commitment = model.commitmentsByID[occurrence.commitmentID]
                    let isIncome = commitment?.direction == .income
                    let isOverdue = model.overdueOccurrenceIDs.contains(occurrence.id)
                    let directionText = isIncome ? String(localized: "Einnahme") : String(localized: "Ausgabe")
                    HStack(spacing: AppSpacing.m) {
                        DateBadge(date: occurrence.scheduledDate)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(commitment?.name ?? String(localized: "Zahlungsplan"))
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(isOverdue ? String(localized: "Überfällig · \(directionText)") : directionText)
                                .font(.caption)
                                .foregroundStyle(isOverdue ? AnyShapeStyle(AppPalette.warning) : AnyShapeStyle(.secondary))
                        }
                        Spacer(minLength: AppSpacing.s)
                        Text("\(isIncome ? "+" : "−")\(money(occurrence.expectedAmount, currency: occurrence.currency))")
                            .font(AppTypography.amount)
                            .monospacedDigit()
                            .foregroundStyle(isIncome ? AppPalette.positive : Color.primary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } accessory: {
            if let onShowRecurring {
                SectionLinkButton(String(localized: "Alle"), action: onShowRecurring)
            }
        }
    }

    // MARK: - Cashflow

    private var historySection: some View {
        PageSection(String(localized: "Cashflow"), subtitle: String(localized: "Einnahmen und Ausgaben der letzten Monate")) {
            MonthlyCashflowChart(points: model.monthlyPoints, currency: model.currency, onMonthTap: onShowTransactionsInMonth, showsHeading: false)
        }
    }

    // MARK: - Kategorien

    private var allocationSection: some View {
        PageSection(
            String(localized: "Top-Kategorien"),
            subtitle: model.isShowingCurrentMonth
                ? String(localized: "Bruttoausgaben diesen Monat")
                : String(localized: "Bruttoausgaben im \(monthTitle)")
        ) {
            if snapshot.spendingByCategory.isEmpty {
                Text("Noch keine Ausgaben in diesem Monat.").font(.callout).foregroundStyle(.secondary)
            } else {
                let top = Array(snapshot.spendingByCategory.prefix(5))
                let total = snapshot.spendingByCategory.reduce(Decimal(0)) { $0 + $1.amount }
                VStack(spacing: AppSpacing.m) {
                    ForEach(top) { category in
                        let meta = category.categoryID.flatMap { model.categoriesByID[$0] }
                        let color = meta?.colorToken.color ?? .gray
                        let share = total > 0 ? NSDecimalNumber(decimal: category.amount / total).doubleValue : 0
                        Button { onOpenCategory(category) } label: {
                            HStack(spacing: AppSpacing.m) {
                                IconTile(systemName: meta?.systemIconName ?? "questionmark", color: color, size: 30)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(category.name)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                        Spacer(minLength: AppSpacing.s)
                                        Text(amountString(category.amount))
                                            .font(AppTypography.amount)
                                            .monospacedDigit()
                                    }
                                    GeometryReader { proxy in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.primary.opacity(0.07))
                                            Capsule().fill(color).frame(width: max(4, proxy.size.width * share))
                                        }
                                    }
                                    .frame(height: 4)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(category.name), \(amountString(category.amount)), \(Int((share * 100).rounded())) Prozent, Buchungen anzeigen")
                    }
                }
            }
        }
    }

    // MARK: - Letzte Buchungen

    private var ledgerTile: some View {
        PageSection(String(localized: "Letzte Buchungen")) {
            if model.recentTransactions.isEmpty {
                Text("Es sind noch keine Transaktionen vorhanden.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.recentTransactions.prefix(7).enumerated()), id: \.element.id) { index, transaction in
                        if index > 0 {
                            Divider().padding(.leading, 48)
                        }
                        ledgerRow(transaction)
                    }
                }
            }
        } accessory: {
            if let onShowAllTransactions {
                SectionLinkButton(String(localized: "Alle anzeigen"), action: onShowAllTransactions)
            }
        }
    }

    private func ledgerRow(_ transaction: Transaction) -> some View {
        let category = model.category(for: transaction)
        let isIncome = transaction.amount.amount > 0
        return Button {
            onOpenTransaction(transaction.id)
        } label: {
            HStack(spacing: AppSpacing.m) {
                IconTile(
                    systemName: category?.systemIconName ?? "questionmark",
                    color: category?.colorToken.color ?? .gray,
                    size: 32
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(transaction.effectiveMerchantName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text("\(category?.name ?? String(localized: "Ohne Kategorie")) · \(AppDateFormatter.day(transaction.displayDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: AppSpacing.m)
                if transaction.status == .pending {
                    StatusBadge(title: String(localized: "Vorgemerkt"), tone: .warning)
                }
                Text(PrivacyAwareMoney.signed(transaction.amount, privacy: privacyState))
                    .font(AppTypography.amount)
                    .monospacedDigit()
                    .foregroundStyle(isIncome ? AppPalette.positive : Color.primary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHighlightButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Transaktion \(transaction.effectiveMerchantName), \(category?.name ?? String(localized: "Ohne Kategorie")), \(PrivacyAwareMoney.accessibilityLabel(transaction.amount, privacy: privacyState, signed: true)) öffnen"
        )
        .accessibilityIdentifier("dashboard.transactionRow")
    }

    // MARK: - Helpers

    /// Ungedeckelter Verbrauch in Prozent (der Balken selbst endet bei 100 %).
    static func percentText(spent: Decimal, limit: Decimal) -> String {
        guard limit > 0 else { return spent > 0 ? "∞" : String(localized: "\(0) %") }
        let ratio = NSDecimalNumber(decimal: spent / limit).doubleValue
        return String(localized: "\(Int((ratio * 100).rounded())) %")
    }

    private func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    private func amountString(_ value: Decimal) -> String {
        money(value, currency: model.currency)
    }

    private func money(_ value: Decimal, currency: CurrencyCode) -> String {
        PrivacyAwareMoney.decimalString(value, currency: currency, privacy: privacyState)
    }
}
