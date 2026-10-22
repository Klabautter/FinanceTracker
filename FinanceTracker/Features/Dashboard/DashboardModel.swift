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
    private(set) var isLoading = false
    /// MacUX-Perf: Erstladung sofort, Revisions-Nachläufe gebündelt (View).
    private(set) var hasLoaded = false
    /// Die Review-Kennzahl kann erst nach dem globalen Projection- und
    /// Annotation-Read als belastbarer Palette-/Toolbar-Wert angezeigt werden.
    private(set) var hasLoadedReviewSummary = false
    private(set) var errorMessage: String?
    /// FX-Status für UI-Debug (Quelle live/cache/fallback + Stand, `nil` =
    /// keine Fremdwährung im Scope). Budgets/Analytics teilen sich denselben
    /// Snapshot: gleiche Kurse überall (#28).
    private(set) var fxSnapshot: FXRateSnapshot?
    private(set) var fxIsLoading = false

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
        isLoading = true
        fxIsLoading = true
        let signpost = PerfSignpost.signposter.beginInterval("DashboardLoad")
        // Alles Sichtbare wird erst am Ende in einem Schritt ausgetauscht.
        // Zwischenstände (geleerte Hinweise, Budgets ohne Zahlen …) ließen
        // die Seite beim Monatswechsel mehrfach springen.
        var newPlanningDataWarning: String?
        var newUpcomingOccurrences: [ScheduledRecurringOccurrence] = []
        var newOverdueOccurrenceIDs: Set<RecurringOccurrenceKey> = []
        var newCommitmentsByID: [UUID: RecurringCommitment] = [:]
        var newBudgetProgresses: [BudgetProgress] = []
        var newForecast: ForecastSnapshot?
        var newFXSnapshot: FXRateSnapshot?
        defer {
            isLoading = false
            fxIsLoading = false
            hasLoaded = true
        }

        let today = now()
        let isCurrentMonth = monthOffset == 0
        guard let anchor = calendar.date(byAdding: .month, value: monthOffset, to: today),
              let currentInterval = monthInterval(containing: anchor) else {
            errorMessage = String(localized: "Der gewählte Monat konnte nicht ermittelt werden.")
            return
        }
        // Vergangene Monate werden als abgeschlossen betrachtet: Stichtag
        // ist ihr letzter Augenblick, damit Verlauf und Budgets den ganzen
        // Monat abbilden.
        let now = isCurrentMonth ? today : currentInterval.end.addingTimeInterval(-1)
        let previousDay = currentInterval.start.addingTimeInterval(-1)
        let previousInterval = monthInterval(containing: previousDay)
        let historyStart = calendar.date(byAdding: .month, value: -5, to: currentInterval.start) ?? currentInterval.start
        let historyEnd = currentInterval.end
        let historyInterval = DateInterval(start: historyStart, end: historyEnd)

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
                        CurrencyConverter(eurPerUnit: $0.eurPerUnit)
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
                        let forecast = ForecastService().forecast(
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
                        return (forecast, upcoming)
                    }.value
                    newForecast = planning.0
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
            errorMessage = nil
            lastImportBatch = newLastImportBatch
            hasAnyTransactions = newHasAnyTransactions
            fxSnapshot = newFXSnapshot
            budgetProgresses = newBudgetProgresses
            planningDataWarning = newPlanningDataWarning
            forecast = newForecast
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
            categoriesByID = Dictionary(
                uniqueKeysWithValues: result.categories.map { ($0.id, $0) }
            )
        } catch {
            errorMessage = String(localized: "Die Auswertung konnte nicht geladen werden.")
        }
        PerfSignpost.signposter.endInterval("DashboardLoad", signpost)
        isLoading = false
        fxIsLoading = false
        hasLoaded = true
        // Die Monatsansicht steht; die Zahl offener Prüfungen gilt für alle
        // Monate und liest den gesamten Bestand. Sie folgt danach, statt die
        // Übersicht bei großen Beständen um Sekunden zu verzögern.
        await loadReviewSummary()
    }

    /// WP13 (§96-99): Der Review-Count ist GLOBAL (leichte Projection +
    /// Annotation-Join), nicht auf 6 Monate begrenzt. Ältere offene
    /// Prüfungen zählen mit; die Review-Queue erreicht sie. Alle Annotationen
    /// direkt zu laden vermeidet ein riesiges `IN (...)` mit bis zu 50k IDs.
    private func loadReviewSummary() async {
        do {
            async let lightRowsTask = dependencies.transactionRepository.reviewCandidateTransactions()
            async let lightAnnotationsTask = dependencies.transactionAnnotationRepository.annotations()
            let lightEffective = effectiveTransactionResolver.applying(
                annotations: try await lightAnnotationsTask,
                to: try await lightRowsTask
            )
            let baseCurrency = dependencies.baseCurrency
            let reviewCalendar = calendar
            reviewSummary = await Task.detached(priority: .userInitiated) {
                ReviewQueueBuilder().buildSummary(
                    transactions: lightEffective,
                    baseCurrency: baseCurrency,
                    calendar: reviewCalendar
                )
            }.value
            hasLoadedReviewSummary = true
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
