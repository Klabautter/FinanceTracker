import Foundation

@MainActor
@Observable
final class BudgetsModel {
    private let dependencies: AppDependencies
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let progressLoader: LoadBudgetProgresses

    private(set) var progresses: [BudgetProgress] = []
    /// Laden (AGENTS #37); Speicher-, Lösch- und Eingabefehler stehen
    /// getrennt in `actionError`.
    private(set) var loadState: LoadState = .idle
    private(set) var actionError: String?
    var isLoading: Bool { loadState.isLoading }
    private(set) var currency: CurrencyCode = .eur
    /// FX-Status für UI-Debug (Quelle live/cache/fallback + Stand, `nil` =
    /// keine Fremdwährung im Scope). Fallback blockiert nie.
    private(set) var fxSnapshot: FXRateSnapshot?
    private(set) var fxIsLoading = false
    private(set) var salaryCycleFallbackBudgetIDs: Set<UUID> = []

    var salaryCycleFallbackWarning: String? {
        guard !salaryCycleFallbackBudgetIDs.isEmpty else { return nil }
        return String(localized: "Mindestens ein Gehaltszyklus-Budget wird mangels ausreichender Gehaltshistorie im Kalendermonat berechnet.")
    }

    var dataRevision: Int { dependencies.changeTracker.revision }

    init(
        dependencies: AppDependencies,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dependencies = dependencies
        self.calendar = calendar
        self.now = now
        self.currency = dependencies.baseCurrency
        self.progressLoader = LoadBudgetProgresses(
            budgetRepository: dependencies.budgetRepository,
            transactionRepository: dependencies.transactionRepository,
            annotationRepository: dependencies.transactionAnnotationRepository,
            splitRepository: dependencies.transactionSplitRepository,
            commitmentRepository: dependencies.recurringCommitmentRepository,
            fxRateProvider: dependencies.fxRateProvider
        )
    }

    func load() async {
        guard !isLoading else { return }
        loadState = .loading
        fxIsLoading = true
        var failure: String?
        let signpost = PerfSignpost.signposter.beginInterval("BudgetLoad")
        defer {
            PerfSignpost.signposter.endInterval("BudgetLoad", signpost)
            loadState = failure.map { .failed($0) } ?? .loaded
            fxIsLoading = false
        }

        do {
            let result = try await progressLoader.execute(
                now: now(),
                calendar: calendar,
                baseCurrency: dependencies.baseCurrency
            )
            progresses = result.progresses
            fxSnapshot = result.fxSnapshot
            salaryCycleFallbackBudgetIDs = result.salaryCycleFallbackBudgetIDs
        } catch {
            failure = String(localized: "Budgets konnten nicht geladen werden.")
        }
    }

    func delete(_ budget: Budget) async {
        do {
            try await dependencies.budgetRepository.delete(id: budget.id)
            await load()
            dependencies.changeTracker.markChanged()
        } catch {
            actionError = String(localized: "Budget konnte nicht gelöscht werden.")
        }
    }

    // MARK: - Summen (WP11 Currency Safety)

    /// WP11: Budgets laufen in der aktuellen Produktphase nur in Base
    /// Currency. Fremdwährungs-Budgets fließen NICHT in die Summen und
    /// werden separat gemeldet (kein stilles Mischen).
    var foreignBudgetCurrencies: [CurrencyCode] {
        Set(progresses.map(\.currency).filter { $0 != dependencies.baseCurrency })
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Buchungen in Währungen ohne Referenzkurs sind bewusst NICHT im
    /// Verbrauch enthalten; das darf nicht still passieren.
    /// (Fremdwährungen MIT Kurs zählen umgerechnet mit, §28.)
    var unconvertibleCurrencies: [CurrencyCode] {
        Set(progresses.flatMap(\.excludedCurrencies))
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Summe der wirksamen Limits (inkl. Übertrag), dieselbe Basis wie
    /// Zeilen, Status und Prognose der einzelnen Budgets.
    var totalLimit: Decimal {
        progresses
            .filter { $0.currency == dependencies.baseCurrency }
            .reduce(into: Decimal(0)) { $0 += $1.effectiveLimit }
    }

    /// Übertrag aus Vorperioden, der im Gesamtlimit steckt.
    var totalCarriedOver: Decimal {
        progresses
            .filter { $0.currency == dependencies.baseCurrency }
            .reduce(into: Decimal(0)) { $0 += $1.effectiveLimit - $1.limit }
    }

    var totalSpent: Decimal {
        progresses
            .filter { $0.currency == dependencies.baseCurrency }
            .reduce(into: Decimal(0)) { $0 += $1.spent }
    }
}
