import Foundation

@MainActor
@Observable
final class DashboardModel {
    private let dependencies: AppDependencies
    private let loader: LoadDashboard
    private let budgetProgressLoader: LoadBudgetProgresses
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let effectiveTransactionResolver = EffectiveTransactionResolver()

    private(set) var snapshot: AnalyticsSnapshot?
    private(set) var previousSnapshot: AnalyticsSnapshot?
    /// Kumulierter Ausgabenverlauf: laufender Monat vs. Vormonat.
    private(set) var spendingPace: SpendingPace?
    private(set) var monthlyPoints: [MonthlyCashflowPoint] = []
    private(set) var recentTransactions: [Transaction] = []
    private(set) var categoriesByID: [UUID: Category] = [:]
    /// WP13 (§97-99): Globale Review-Kennzahl aus der leichten Projection:
    /// „N Transaktionen prüfen" heißt wirklich N insgesamt.
    private(set) var reviewSummary = ReviewSummary(
        uncategorizedCount: 0,
        unknownMerchantCount: 0,
        transferCandidateCount: 0,
        foreignCurrencyCount: 0
    )
    private(set) var budgetProgresses: [BudgetProgress] = []
    private(set) var upcomingOccurrences: [ScheduledRecurringOccurrence] = []
    /// Unbezahlte Termine aus `upcomingOccurrences`, deren Fälligkeitstag vorbei ist.
    private(set) var overdueOccurrenceIDs: Set<RecurringOccurrenceKey> = []
    private(set) var commitmentsByID: [UUID: RecurringCommitment] = [:]
    var attentionBudgets: [BudgetProgress] {
        Array(budgetProgresses.sorted { lhs, rhs in
            if lhs.fraction != rhs.fraction { return lhs.fraction > rhs.fraction }
            return lhs.budget.name.localizedStandardCompare(rhs.budget.name) == .orderedAscending
        }.prefix(3))
    }
    private(set) var forecast: ForecastSnapshot?
    @ObservationIgnored private var forecastInputs: ForecastInputs?
    /// „Was wäre, wenn": Zahlungspläne, die testweise wegfallen.
    var whatIfExcludedCommitmentIDs: Set<UUID> = []

    /// Zahlungspläne, die im laufenden Monat noch anstehen (für „Was wäre,
    /// wenn"), nach Termin.
    var whatIfCandidates: [RecurringCommitment] {
        guard let inputs = forecastInputs else { return [] }
        // Halboffen: ein Termin am Monatsersten des Folgemonats gehört nicht dazu.
        let open = Set(upcomingOccurrences.filter { inputs.period.containsHalfOpen($0.scheduledDate) }.map(\.commitmentID))
        return inputs.commitments.filter { open.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Prognose ohne die abgewählten Zahlungspläne; `nil` ohne Abwahl.
    var whatIfForecast: ForecastSnapshot? {
        guard !whatIfExcludedCommitmentIDs.isEmpty, let forecastInputs else { return nil }
        return forecastInputs.forecast(excludingCommitments: whatIfExcludedCommitmentIDs)
    }
    /// Der Dashboard-Cashflow bleibt nutzbar, wenn optionale Planungsdaten
    /// fehlschlagen. Eine präzise Forecast-Zahl darf dann aber nicht aus
    /// unvollständigen Eingaben berechnet werden.
    private(set) var planningDataWarning: String?
    private(set) var lastImportBatch: ImportBatch?
    private(set) var dashboardInterval: DateInterval?
    private(set) var hasAnyTransactions = false
    /// Angezeigter Monat relativ zum laufenden: 0 = aktueller Monat,
    /// negative Werte = vergangene Monate. Zukunft ist nicht wählbar.
    private(set) var monthOffset = 0
    var isShowingCurrentMonth: Bool { monthOffset == 0 }
    /// Ein Monatswechsel während eines laufenden Ladevorgangs darf nicht
    /// verloren gehen; der Ladevorgang wird danach einmal wiederholt.
    private var needsReload = false
    /// Laden der Übersicht (AGENTS #37). Ein neuer Ladevorgang ersetzt
    /// einen alten Fehler sofort; die alten Zahlen bleiben währenddessen.
    private(set) var loadState: LoadState = .idle
    var isLoading: Bool { loadState.isLoading }
    /// MacUX-Perf: Erstladung sofort, Revisions-Nachläufe gebündelt (View).
    private(set) var hasLoaded = false
    /// Die Review-Kennzahl kann erst nach dem globalen Projection- und
    /// Annotation-Read als belastbarer Palette-/Toolbar-Wert angezeigt werden.
    private(set) var hasLoadedReviewSummary = false
    /// FX-Status für UI-Debug (Quelle live/cache/fallback + Stand, `nil` =
    /// keine Fremdwährung im Scope). Budgets/Analytics teilen sich denselben
    /// Snapshot: gleiche Kurse überall (#28).
    private(set) var fxSnapshot: FXRateSnapshot?
    private(set) var fxIsLoading = false
    /// Gesamtstand der liquiden Mittel (nur laufender Monat).
    private(set) var liquidity: LiquidityOverview?
    /// Auffälligkeiten des laufenden Monats (Abo teurer, doppelt, …).
    private(set) var insights: [SpendingInsight] = []
    /// Kontostände und Prüfzahl lesen den ganzen Bestand (bei 50.000
    /// Buchungen je über eine Sekunde). Je Datenstand nur einmal: Monats-
    /// wechsel und Rückkehr zur Übersicht nutzen das Ergebnis weiter.
    @ObservationIgnored private var balancesCache: (revision: Int, balances: AccountBalances)?
    @ObservationIgnored private var reviewSummaryRevision: Int?
    private static let dismissedInsightsKey = "dismissedSpendingInsights"

    /// Blendet einen Hinweis dauerhaft aus (gilt für genau diese Ursache).
    func dismissInsight(_ insight: SpendingInsight) {
        var dismissed = Set(dependencies.userDefaults.stringArray(forKey: Self.dismissedInsightsKey) ?? [])
        dismissed.insert(insight.id)
        dependencies.userDefaults.set(Array(dismissed), forKey: Self.dismissedInsightsKey)
        insights.removeAll { $0.id == insight.id }
    }
    private(set) var runway: LiquidityRunway?

    init(
        dependencies: AppDependencies,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dependencies = dependencies
        self.calendar = calendar
        self.now = now
        self.loader = LoadDashboard(
            transactionRepository: dependencies.transactionRepository,
            transactionAnnotationRepository: dependencies.transactionAnnotationRepository,
            transactionSplitRepository: dependencies.transactionSplitRepository,
            categoryRepository: dependencies.categoryRepository
        )
        self.budgetProgressLoader = LoadBudgetProgresses(
            budgetRepository: dependencies.budgetRepository,
            transactionRepository: dependencies.transactionRepository,
            annotationRepository: dependencies.transactionAnnotationRepository,
            splitRepository: dependencies.transactionSplitRepository,
            commitmentRepository: dependencies.recurringCommitmentRepository,
            fxRateProvider: dependencies.fxRateProvider
        )
    }

    func showPreviousMonth() async {
        monthOffset -= 1
        await load()
    }

    func showNextMonth() async {
        guard monthOffset < 0 else { return }
        monthOffset += 1
        await load()
    }

    func showCurrentMonth() async {
        guard monthOffset != 0 else { return }
        monthOffset = 0
        await load()
    }

    func load() async {
        if isLoading {
            needsReload = true
            return
        }
        repeat {
            needsReload = false
            await performLoad()
        } while needsReload
    }

    private func performLoad() async {
        loadState = .loading
        fxIsLoading = true
        var failure: String?
        let signpost = PerfSignpost.signposter.beginInterval("DashboardLoad")
        // Kontostände und Prüfzahl brauchen den ganzen Bestand: EINE leichte
        // Abfrage für beide, parallel zur Monatsansicht.
        let revision = dependencies.changeTracker.revision
        let needsLightRows = balancesCache?.revision != revision
            || !(hasLoadedReviewSummary && reviewSummaryRevision == revision)
        let repository = dependencies.transactionRepository
        // Alles Sichtbare wird erst am Ende in einem Schritt ausgetauscht.
        // Zwischenstände (geleerte Hinweise, Budgets ohne Zahlen …) ließen
        // die Seite beim Monatswechsel mehrfach springen.
        var newPlanningDataWarning: String?
        var newUpcomingOccurrences: [ScheduledRecurringOccurrence] = []
        var newOverdueOccurrenceIDs: Set<RecurringOccurrenceKey> = []
        var newCommitmentsByID: [UUID: RecurringCommitment] = [:]
        var newBudgetProgresses: [BudgetProgress] = []
        var newForecast: ForecastSnapshot?
        var newForecastInputs: ForecastInputs?
        var newFXSnapshot: FXRateSnapshot?
        defer {
            loadState = failure.map { .failed($0) } ?? .loaded
            fxIsLoading = false
            hasLoaded = true
        }

        let today = now()
        let isCurrentMonth = monthOffset == 0
        guard let anchor = calendar.date(byAdding: .month, value: monthOffset, to: today),
              let currentInterval = monthInterval(containing: anchor) else {
            failure = String(localized: "Der gewählte Monat konnte nicht ermittelt werden.")
            return
        }
        // Vergangene Monate werden als abgeschlossen betrachtet: Stichtag
        // ist ihr letzter Augenblick, damit Verlauf und Budgets den ganzen
        // Monat abbilden.
        let now = isCurrentMonth ? today : currentInterval.end.addingTimeInterval(-1)
        let previousDay = currentInterval.start.addingTimeInterval(-1)
        let previousInterval = monthInterval(containing: previousDay)
        // Derselbe Rückblick wie in „Wiederkehrend" (letzte reale Zahlung).
        let historyInterval = RecurringOccurrenceResolver.latestPaymentPeriod(
            endingWith: currentInterval,
            calendar: calendar
        )

        do {
            let request = LoadDashboardRequest(
                currentMonthInterval: currentInterval,
                previousMonthInterval: previousInterval,
                historyInterval: historyInterval
            )
            async let resultTask = loader.execute(
                request,
                baseCurrency: dependencies.baseCurrency,
                fxRateProvider: dependencies.fxRateProvider,
                calendar: calendar
            )
            let balanceConverter = await dependencies.fxRateProvider.converter()
            async let latestBatchTask = dependencies.importBatchRepository.latestBatch()
            async let transactionCountTask = dependencies.transactionRepository.count()

            let result = try await resultTask
            let newLastImportBatch = try await latestBatchTask
            let newHasAnyTransactions = try await transactionCountTask > 0

            // Der Loader liefert dieselbe bereits annotierte History, aus der
            // auch Current/Previous/Charts berechnet wurden. Damit entfallen
            // ein doppelter History-Read und ein zweiter Annotation-Join.
            // Sein FX-Snapshot gilt weiter für Budgets (#28: gleiche Kurse).
            let historyTxns = result.historyTransactions
            newFXSnapshot = result.fxSnapshot

            let baseCurrency = dependencies.baseCurrency

            var hasCompleteBudgetData = true
            let budgets: [Budget]
            let activeCommitments: [RecurringCommitment]
            do {
                let budgetResult = try await budgetProgressLoader.execute(
                    now: now,
                    calendar: calendar,
                    baseCurrency: baseCurrency,
                    preferredFXSnapshot: result.fxSnapshot
                )
                budgets = budgetResult.budgets
                activeCommitments = budgetResult.commitments.filter { $0.status == .active }
                newBudgetProgresses = budgetResult.progresses
                newFXSnapshot = budgetResult.fxSnapshot ?? result.fxSnapshot
                if !budgetResult.salaryCycleFallbackBudgetIDs.isEmpty {
                    newPlanningDataWarning = String(localized: "Mindestens ein Gehaltszyklus-Budget wird mangels ausreichender Gehaltshistorie im Kalendermonat berechnet.")
                }
            } catch {
                budgets = []
                activeCommitments = []
                hasCompleteBudgetData = false
                newBudgetProgresses = []
                newPlanningDataWarning = String(localized: "Planungsdaten sind derzeit unvollständig. Die verfügbare Monatssumme wird deshalb nicht geschätzt.")
            }

            // Roadmap #120–127 / WP7: Forecast für den Hero („Noch verfügbar“).
            // Occurrences + letzte Zahlungen machen geplante Termine
            // planbar (occurrences-basierte Fixkosten/Einnahmen).
            do {
                let explicitOccurrences = try await dependencies.recurringCommitmentRepository.allOccurrences()
                // Prognose und anstehende Termine gibt es nur für den
                // laufenden Monat; ein abgeschlossener Monat hat keinen Rest.
                if hasCompleteBudgetData, isCurrentMonth {
                    let progresses = newBudgetProgresses
                    let calculationCalendar = calendar
                    let forecastCurrencyConverter = newFXSnapshot.map {
                        $0.converter
                    } ?? CurrencyConverter()
                    let planning = await Task.detached(priority: .userInitiated) {
                        // Dieselbe explizit-vor-heuristisch Semantik wie im
                        // Fixkosten-Screen. So basiert der Forecast nicht
                        // nur auf manuell zugeordneten Zahlungen.
                        let occurrencesByCommitment = Dictionary(
                            grouping: explicitOccurrences,
                            by: \.commitmentID
                        )
                        let resolver = RecurringOccurrenceResolver()
                        var latestOccurrences: [UUID: Date] = [:]
                        for commitment in activeCommitments {
                            let result = resolver.resolve(
                                commitment: commitment,
                                explicitOccurrences: occurrencesByCommitment[commitment.id] ?? [],
                                allTransactions: historyTxns,
                                period: historyInterval,
                                calendar: calculationCalendar
                            )
                            latestOccurrences[commitment.id] = result.latestOccurrence
                        }
                        let monthTxns = historyTxns.filter {
                            currentInterval.containsHalfOpen($0.displayDate)
                        }
                        let upcomingEnd = calculationCalendar.date(byAdding: .day, value: 30, to: now) ?? now
                        let upcoming = activeCommitments.filter { $0.nextExpectedDate != nil || latestOccurrences[$0.id] != nil }.flatMap { commitment in
                            // Inklusive heute fälliger und kürzlich überfälliger Termine.
                            resolver.openOccurrences(
                                commitment: commitment,
                                explicitOccurrences: occurrencesByCommitment[commitment.id] ?? [],
                                allTransactions: historyTxns,
                                now: now,
                                end: upcomingEnd,
                                calendar: calculationCalendar,
                                latestPaymentDate: latestOccurrences[commitment.id]
                            )
                        }.sorted { $0.scheduledDate < $1.scheduledDate }
                        let inputs = ForecastInputs(
                            period: currentInterval,
                            transactions: monthTxns,
                            budgets: budgets,
                            budgetProgresses: progresses,
                            commitments: activeCommitments,
                            explicitOccurrences: explicitOccurrences,
                            latestOccurrences: latestOccurrences,
                            baseCurrency: baseCurrency,
                            calendar: calculationCalendar,
                            now: now,
                            currencyConverter: forecastCurrencyConverter
                        )
                        return (inputs.forecast(), upcoming, inputs)
                    }.value
                    newForecast = planning.0
                    newForecastInputs = planning.2
                    newUpcomingOccurrences = planning.1
                    newOverdueOccurrenceIDs = Set(
                        planning.1.filter { $0.isOverdue(now: now, calendar: calculationCalendar) }.map(\.id)
                    )
                    newCommitmentsByID = Dictionary(uniqueKeysWithValues: activeCommitments.map { ($0.id, $0) })
                }
            } catch {
                newForecast = nil
                if newPlanningDataWarning == nil {
                    newPlanningDataWarning = String(localized: "Planungsdaten sind derzeit unvollständig. Die verfügbare Monatssumme wird deshalb nicht geschätzt.")
                }
            }

            // Zeitraum, Zahlen, Hinweise und Planung wechseln gemeinsam: Sonst
            // stünde beim Monatswechsel kurz der neue Titel über den alten
            // Werten, und die Seite würde mehrfach neu umbrechen.
            lastImportBatch = newLastImportBatch
            hasAnyTransactions = newHasAnyTransactions
            fxSnapshot = newFXSnapshot
            budgetProgresses = newBudgetProgresses
            planningDataWarning = newPlanningDataWarning
            forecast = newForecast
            forecastInputs = newForecastInputs
            whatIfExcludedCommitmentIDs = whatIfExcludedCommitmentIDs.filter { id in
                newForecastInputs?.commitments.contains { $0.id == id } == true
            }
            upcomingOccurrences = newUpcomingOccurrences
            overdueOccurrenceIDs = newOverdueOccurrenceIDs
            commitmentsByID = newCommitmentsByID
            dashboardInterval = currentInterval
            snapshot = result.current
            previousSnapshot = result.previous
            spendingPace = SpendingPace.make(
                currentDaily: result.current.dailySpending,
                currentInterval: currentInterval,
                previousDaily: result.previous?.dailySpending ?? [],
                previousInterval: previousInterval,
                now: now,
                calendar: calendar
            )
            monthlyPoints = result.monthlyPoints
            recentTransactions = result.recentTransactions
            if isCurrentMonth {
                let dismissed = Set(dependencies.userDefaults.stringArray(forKey: Self.dismissedInsightsKey) ?? [])
                let detectionInput = (historyTxns, Array(newCommitmentsByID.values), newBudgetProgresses)
                let detectionCalendar = calendar
                let detected = await Task.detached(priority: .userInitiated) {
                    SpendingInsightDetector().detect(
                        transactions: detectionInput.0,
                        commitments: detectionInput.1,
                        budgetProgresses: detectionInput.2,
                        now: now,
                        calendar: detectionCalendar
                    )
                }.value
                insights = detected.filter { !dismissed.contains($0.id) }
            } else {
                insights = []
            }
            categoriesByID = Dictionary(
                uniqueKeysWithValues: result.categories.map { ($0.id, $0) }
            )
            // Die Monatsansicht steht: sofort zeigen. Kontostände und die
            // Zahl offener Prüfungen brauchen den ganzen Bestand (bei
            // 100.000 Buchungen Sekunden) und füllen ihre Bereiche danach.
            // Beim Monatswechsel liegen sie im Cache, dort springt nichts.
            loadState = .loaded
            fxIsLoading = false
            hasLoaded = true
            // Erst jetzt die große Abfrage: Alle Abfragen laufen über einen
            // Persistenz-Actor, parallel gestartet stünde die Monatsansicht
            // hinter ihr in der Schlange.
            let lightRowsTask: Task<[Transaction], Error>? = needsLightRows
                ? Task { try await repository.reviewCandidateTransactions() }
                : nil
            async let reviewSummaryLoad: Void = loadReviewSummary(lightRows: lightRowsTask)
            if isCurrentMonth, let balances = try? await cachedBalances(converter: balanceConverter, lightRows: lightRowsTask) {
                let calculator = LiquidityCalculator(
                    baseCurrency: dependencies.baseCurrency,
                    converter: balanceConverter
                )
                let overview = calculator.overview(of: balances.active)
                liquidity = overview.shares.isEmpty ? nil : overview
                runway = liquidity.flatMap {
                    calculator.runway(total: $0.total, monthlyPoints: result.monthlyPoints, now: today, calendar: calendar)
                }
            } else {
                liquidity = nil
                runway = nil
            }
            // Die Zahl offener Prüfungen gilt für alle Monate.
            await reviewSummaryLoad
        } catch {
            failure = String(localized: "Die Auswertung konnte nicht geladen werden.")
            await loadReviewSummary()
        }
        PerfSignpost.signposter.endInterval("DashboardLoad", signpost)
    }

    /// WP13 (§96-99): Der Review-Count ist GLOBAL (leichte Projection +
    /// Annotation-Join), nicht auf 6 Monate begrenzt. Ältere offene
    /// Prüfungen zählen mit; die Review-Queue erreicht sie. Alle Annotationen
    /// direkt zu laden vermeidet ein riesiges `IN (...)` mit bis zu 50k IDs.
    private func cachedBalances(converter: CurrencyConverter, lightRows: Task<[Transaction], Error>?) async throws -> AccountBalances {
        let revision = dependencies.changeTracker.revision
        if let balancesCache, balancesCache.revision == revision { return balancesCache.balances }
        let movements = try await lightRows?.value.map(AccountMovementRow.init(transaction:))
        let balances = try await LoadAccountBalances(
            accountRepository: dependencies.accountRepository,
            transactionRepository: dependencies.transactionRepository
        ).execute(converter: converter, calendar: calendar, knownMovements: movements)
        balancesCache = (revision, balances)
        return balances
    }

    private func loadReviewSummary(lightRows: Task<[Transaction], Error>? = nil) async {
        let revision = dependencies.changeTracker.revision
        guard !(hasLoadedReviewSummary && reviewSummaryRevision == revision) else { return }
        do {
            let repository = dependencies.transactionRepository
            let rowsTask = lightRows ?? Task { try await repository.reviewCandidateTransactions() }
            async let lightAnnotationsTask = dependencies.transactionAnnotationRepository.annotations()
            let lightEffective = effectiveTransactionResolver.applying(
                annotations: try await lightAnnotationsTask,
                to: try await rowsTask.value
            )
            let baseCurrency = dependencies.baseCurrency
            let reviewCalendar = calendar
            let accountCurrencies = Dictionary(
                uniqueKeysWithValues: try await dependencies.accountRepository.accounts().map { ($0.id, $0.currency) }
            )
            let converter = await dependencies.fxRateProvider.converter()
            reviewSummary = await Task.detached(priority: .userInitiated) {
                ReviewQueueBuilder().buildSummary(
                    transactions: lightEffective,
                    baseCurrency: baseCurrency,
                    accountCurrencies: accountCurrencies,
                    converter: converter,
                    calendar: reviewCalendar
                )
            }.value
            hasLoadedReviewSummary = true
            reviewSummaryRevision = revision
        } catch {
            // Die Monatsansicht bleibt gültig; der Prüfhinweis fehlt nur.
        }
    }

    func category(for transaction: Transaction) -> Category? {
        guard let categoryID = transaction.categoryID else { return nil }
        return categoriesByID[categoryID]
    }

    var currency: CurrencyCode { dependencies.baseCurrency }

    var dataRevision: Int { dependencies.changeTracker.revision }

    var dependenciesForReview: AppDependencies { dependencies }

    var spendingTrendPercent: Decimal? {
        guard let current = snapshot?.totalSpending,
              let previous = previousSnapshot?.totalSpending else { return nil }
        return Self.spendingTrendPercentagePoints(current: current, previous: previous)
    }

    static func spendingTrendPercentagePoints(current: Decimal, previous: Decimal) -> Decimal? {
        guard previous > 0, current >= 0 else { return nil }
        return ((current - previous) / previous) * 100
    }

    static func roundedTrendPercentage(_ percentagePoints: Decimal) -> Int {
        NSDecimalNumber(decimal: abs(percentagePoints)).rounding(accordingToBehavior:
            NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
        ).intValue
    }

    private func monthInterval(containing date: Date) -> DateInterval? {
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }

}

extension DashboardModel {
    /// Lädt und misst, wann die Monatsansicht sichtbar ist und wann alles
    /// (inklusive Kontostände und Prüfzahl) fertig ist. Für Leistungstests
    /// und den Rauchtest der fertigen App.
    func measureLoad() async -> (visible: Duration, complete: Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { await self.load() }
        var visible: Duration?
        while visible == nil {
            switch loadState {
            case .loaded, .failed: visible = clock.now - start
            case .idle, .loading: try? await Task.sleep(for: .milliseconds(2))
            }
        }
        await task.value
        return (visible ?? clock.now - start, clock.now - start)
    }
}

