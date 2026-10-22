import SwiftUI
import Charts

/// Eingebettetes Budget-Detail für Navigation und macOS-Inspector.
struct BudgetDetailSheet: View {
    let progress: BudgetProgress
    let dependencies: AppDependencies
    let onEdit: () -> Void

    @State private var contributions: [BudgetContribution] = []
    @State private var amountHistory: [BudgetAmountHistory] = []
    @State private var categories: [Category] = []
    @State private var fxSnapshot: FXRateSnapshot?
    @State private var fxIsLoading = false
    @State private var isLoading = true
    @State private var loadErrorMessage: String?
    @Environment(PrivacyPresentationState.self) private var privacyState

    private let effectiveTransactionResolver = EffectiveTransactionResolver()

    private var statusTone: AppTone {
        if progress.isOverBudget { return .critical }
        if progress.fraction >= 0.85 { return .warning }
        return .positive
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: AppSpacing.s) {
                        HStack(spacing: AppSpacing.m) {
                            IconTile(systemName: progress.budget.systemIconName, color: statusTone.foregroundColor, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(progress.budget.name)
                                    .font(.headline)
                                Text(BudgetOverviewPresentation.periodRange(progress.period))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(PrivacyAwareMoney.decimalString(progress.spent, currency: progress.currency, privacy: privacyState))
                                .font(AppTypography.largeMetric.monospacedDigit())
                                .foregroundStyle(progress.isOverBudget ? AppPalette.critical : .primary)
                            Text("von \(PrivacyAwareMoney.decimalString(progress.effectiveLimit, currency: progress.currency, privacy: privacyState))")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        (progress.isOverBudget
                             ? Text("\(PrivacyAwareMoney.decimalString(BudgetOverviewPresentation.variance(for: progress), currency: progress.currency, privacy: privacyState)) überschritten")
                             : Text("\(PrivacyAwareMoney.decimalString(progress.remaining, currency: progress.currency, privacy: privacyState)) verbleibend"))
                            .font(.caption)
                            .foregroundStyle(progress.isOverBudget ? AppPalette.critical : .secondary)
                        FinanceProgressBar(fraction: progress.fraction, tone: statusTone, height: 8)
                            .accessibilityLabel("Budgetverbrauch")
                        if fxSnapshot != nil || fxIsLoading {
                            FXRateStatusView(snapshot: fxSnapshot, isLoading: fxIsLoading)
                        }
                    Button("Bearbeiten", action: onEdit)
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .accessibilityLabel("Budget \(progress.budget.name) bearbeiten")
                }
                .padding(.vertical, 4)
            }

            Section("Zeitraum & Kategorien") {
                    LabeledContent(
                        "Periodentyp",
                        value: BudgetOverviewPresentation.periodType(for: progress.budget)
                    )
                    LabeledContent(
                        "Zeitraum",
                        value: BudgetOverviewPresentation.periodRange(progress.period)
                    )
                    if isLoading {
                        ProgressView("Kategorien werden geladen…")
                    } else if categories.isEmpty {
                        (progress.budget.categoryIDs.isEmpty && progress.budget.isSalaryCycle
                             ? Text("Alle Ausgabenkategorien")
                             : Text("Keine Kategorien zugeordnet"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(categories) { category in
                            HStack(spacing: AppSpacing.s) {
                                IconTile(systemName: category.systemIconName, color: category.colorToken.color, size: 22)
                                Text(category.name)
                            }
                        }
                    }
            }

            if progress.budget.rolloverPolicy == .accumulate {
                Section {
                        Label("Rücklagen-Budget: Nicht ausgegebene Beträge werden übertragen.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                }
            }

            if let goal = savingsGoal {
                Section("Sparziel") {
                    HStack {
                        LabeledMetric(
                            label: String(localized: "Gespart"),
                            value: PrivacyAwareMoney.decimalString(goal.saved, currency: goal.currency, privacy: privacyState),
                            valueColor: goal.isReached ? AppPalette.positive : .primary
                        )
                        Spacer()
                        LabeledMetric(
                            label: String(localized: "Ziel"),
                            value: PrivacyAwareMoney.decimalString(goal.target, currency: goal.currency, privacy: privacyState)
                        )
                    }
                    FinanceProgressBar(fraction: goal.fraction, tone: goal.isReached ? .positive : .accent, height: 8)
                        .accessibilityLabel("Sparziel \(Int(goal.fraction * 100)) Prozent erreicht")
                    if let targetDate = goal.targetDate {
                        LabeledContent("Zieldatum", value: AppDateFormatter.day(targetDate))
                    }
                    if let requiredMonthly = goal.requiredMonthly {
                        LabeledContent(
                            "Benötigt / Monat",
                            value: PrivacyAwareMoney.decimalString(requiredMonthly, currency: goal.currency, privacy: privacyState)
                        )
                    }
                    (goal.isReached
                        ? Text("Ziel erreicht.")
                        : Text("\(PrivacyAwareMoney.decimalString(goal.shortfall, currency: goal.currency, privacy: privacyState)) fehlen noch."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

                // Roadmap #101: Lineare Prognose für das tatsächliche
                // Periodenende (Kalendermonat oder Gehaltszyklus).
            if let projection = periodEndProjection {
                Section("Prognose") {
                        HStack {
                            LabeledMetric(
                                label: String(localized: "Prognose Periodenende"),
                                value: PrivacyAwareMoney.decimalString(projection, currency: progress.currency, privacy: privacyState),
                                valueColor: projection > progress.effectiveLimit ? AppPalette.critical : .primary
                            )
                            Spacer()
                        }
                }
            }

            if !isLoading, !amountHistory.isEmpty {
                Section("Verlauf") {
                        ForEach(sortedHistory) { entry in
                            LabeledContent(
                                AppDateFormatter.monthYear(entry.periodStart),
                                value: PrivacyAwareMoney.decimalString(entry.amount, currency: entry.currency, privacy: privacyState)
                            )
                        }
                }
            }

            if !isLoading, loadErrorMessage == nil, !contributions.isEmpty {
                Section("Trend") {
                        cumulativeTrend
                            .frame(height: 120)
                }
            }

            Section("Beiträge dieser Periode") {
                    if isLoading {
                        ProgressView("Beiträge werden geladen…")
                    } else if let loadErrorMessage {
                        Label(loadErrorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AppPalette.critical)
                        Button("Erneut laden") {
                            Task { await load() }
                        }
                    } else if contributions.isEmpty {
                        Text("Keine Beiträge gefunden.")
                            .foregroundStyle(.secondary)
                    } else {
                        // WP9: Die Liste zeigt exakt die Contributions der
                        // gemeinsamen Pipeline (Header == Summe der Liste).
                        ForEach(contributions.prefix(50)) { contribution in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contribution.isSplitLine ? (contribution.note ?? String(localized: "Split-Position")) : contribution.merchantName)
                                        .lineLimit(1)
                                    HStack(spacing: AppSpacing.xs) {
                                        Text(AppDateFormatter.day(contribution.date))
                                        // Umgerechnete Beträge
                                        // niemals wie native ausweisen.
                                        if let origin = contribution.convertedFrom {
                                            Text("· \(origin.rawValue) zum Referenzkurs")
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(PrivacyAwareMoney.decimalString(contribution.amount, currency: progress.currency, privacy: privacyState))
                                    .font(.callout.monospacedDigit())
                            }
                        }
                        if contributions.count > 50 {
                            Label(
                                "50 von \(contributions.count) Beiträgen angezeigt. Die Budgetsumme berücksichtigt alle Beiträge.",
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .financeFormStyle()
        .workspaceNavigationTitle(progress.budget.name)
        .accessibilityIdentifier("budget-detail-\(progress.budget.name)")
        .task(id: progress) { await load() }
    }

    /// WP6 (§46-48): Das Detail verwendet EXAKT die Periode aus dem
    /// BudgetProgress: dieselbe Auflösung wie die Übersicht, kein
    /// eigener Resolver-Aufruf (Overview == Detail per Konstruktion).
    private var currentPeriodInterval: DateInterval {
        progress.period
    }

    private var periodEndProjection: Decimal? {
        BudgetOverviewPresentation.projection(for: progress)
    }

    /// P2 Sparziel-Fortschritt aus dem Budget-Progress (gleiche Währung,
    /// keine Conversion). Nil = kein Sparziel gesetzt.
    private var savingsGoal: SavingsGoalProgress? {
        SavingsGoalCalculator().goalProgress(for: progress)
    }

    private var sortedHistory: [BudgetAmountHistory] {
        amountHistory.sorted { $0.periodStart > $1.periodStart }
    }

    /// WP9: Kumulativer Ausgabenverlauf ausschließlich über die
    /// effektiven Budget-Contributions (nicht über rohe Beträge);
    /// das Trend-Ende ist damit identisch mit dem Header.
    private var cumulativeTrend: some View {
        let dailyTotals = Dictionary(grouping: contributions, by: { contribution in
            Calendar.current.startOfDay(for: contribution.date)
        })
        let days = dailyTotals.keys.sorted()
        var cumulative: [(day: Date, amount: Decimal)] = []
        var running: Decimal = 0
        for day in days {
            let daySum = (dailyTotals[day] ?? []).reduce(into: Decimal(0)) { $0 += $1.amount }
            running += daySum
            cumulative.append((day, running))
        }

        let lineColor = progress.isOverBudget ? AppPalette.critical : Color.accentColor
        return Chart {
            ForEach(cumulative, id: \.day) { point in
                AreaMark(
                    x: .value("Datum", point.day, unit: .day),
                    y: .value("Kumuliert", NSDecimalNumber(decimal: point.amount).doubleValue)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [lineColor.opacity(0.2), lineColor.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(
                    x: .value("Datum", point.day, unit: .day),
                    y: .value("Kumuliert", NSDecimalNumber(decimal: point.amount).doubleValue)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .foregroundStyle(lineColor)
            }
            RuleMark(y: .value("Limit", NSDecimalNumber(decimal: progress.effectiveLimit).doubleValue))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) {
                    Text("Limit")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
        }
        .chartYAxis {
            if !privacyState.hidesAmounts {
                AxisMarks(position: .trailing)
            }
        }
        .chartAccessibilitySummary(
            "Kumulierter Ausgabenverlauf im Monat, aktuell \(PrivacyAwareMoney.accessibilityLabel(running, currency: progress.currency, privacy: privacyState))"
        )
    }

    private func load() async {
        isLoading = true
        fxIsLoading = false
        loadErrorMessage = nil
        contributions = []
        amountHistory = []
        categories = []
        fxSnapshot = nil
        defer {
            isLoading = false
            fxIsLoading = false
        }

        do {
            async let historyTask = dependencies.budgetRepository.amountHistory(budgetID: progress.budget.id)
            async let categoriesTask = dependencies.categoryRepository.categories()

            // WP8/WP9: Die Detail-Query nutzt IMMER die Resolver-Periode des
            // Budgets (nicht alle historischen Transactions der Kategorie).
            var query = TransactionQuery()
            query.categoryIDs = progress.budget.categoryIDs
            query.dateInterval = currentPeriodInterval
            async let transactionsTask = dependencies.transactionRepository.transactions(matching: query)
            let (history, allCategories, periodRaw) = try await (historyTask, categoriesTask, transactionsTask)
            amountHistory = history
            categories = allCategories
                .filter { progress.budget.categoryIDs.contains($0.id) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // WP9: Dieselbe effektive Semantik wie der Budget-Header:
            // Annotationen auflösen, Split-Lines laden, dann die gemeinsame
            // Contribution-Pipeline.
            let annotations = try await dependencies.transactionAnnotationRepository.annotations(
                transactionIDs: Set(periodRaw.map(\.id))
            )
            let effective = effectiveTransactionResolver.applying(annotations: annotations, to: periodRaw)

            // WP11 (§83-84): Split-Lines SCOPED auf die Parent-Transactions
            // der Periode, kein Full-Split-Load. Kein try?: Split-Fehler
            // dürfen keine falsche Budgetzahl zeigen (§85).
            let splitLines = try await dependencies.transactionSplitRepository.splitLines(
                parentTransactionIDs: Set(periodRaw.map(\.id))
            )
            // Fremdwährung nur dann über den FX-Provider umrechnen (#19/#35);
            // reine Basiswährung braucht kein I/O.
            let needsFX = effective.contains { $0.amount.currency != progress.budget.currency }
            let converter: CurrencyConverter
            if needsFX {
                fxIsLoading = true
                let snapshot = await dependencies.fxRateProvider.snapshot()
                fxIsLoading = false
                fxSnapshot = snapshot
                converter = CurrencyConverter(eurPerUnit: snapshot.eurPerUnit)
            } else {
                fxSnapshot = nil
                converter = CurrencyConverter()
            }
            contributions = BudgetContributionCalculator(converter: converter).contributions(
                budget: progress.budget,
                transactions: effective,
                splitLines: splitLines,
                period: currentPeriodInterval
            )
        } catch {
            // WP11 (§86): Fehler nie als „keine Splits" maskieren; sichtbare
            // Fehlermeldung statt scheinbar präziser Zahl.
            contributions = []
            categories = []
            loadErrorMessage = String(localized: "Budgetdaten konnten nicht vollständig geladen werden.")
        }
    }
}
