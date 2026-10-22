import Foundation

@MainActor
@Observable
final class BudgetsModel {
    private let dependencies: AppDependencies
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let progressLoader: LoadBudgetProgresses

    private(set) var progresses: [BudgetProgress] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
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
        isLoading = true
        fxIsLoading = true
        errorMessage = nil
        let signpost = PerfSignpost.signposter.beginInterval("BudgetLoad")
        defer {
            PerfSignpost.signposter.endInterval("BudgetLoad", signpost)
            isLoading = false
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
            errorMessage = String(localized: "Budgets konnten nicht geladen werden.")
        }
    }

    func delete(_ budget: Budget) async {
        do {
            try await dependencies.budgetRepository.delete(id: budget.id)
            await load()
            dependencies.changeTracker.markChanged()
        } catch {
            errorMessage = String(localized: "Budget konnte nicht gelöscht werden.")
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

    var totalLimit: Decimal {
        progresses
            .filter { $0.currency == dependencies.baseCurrency }
            .reduce(into: Decimal(0)) { $0 += $1.limit }
    }

    var totalSpent: Decimal {
        progresses
            .filter { $0.currency == dependencies.baseCurrency }
            .reduce(into: Decimal(0)) { $0 += $1.spent }
    }
}
