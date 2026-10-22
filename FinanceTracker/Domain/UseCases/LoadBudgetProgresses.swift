import Foundation

struct BudgetProgressLoadResult: Sendable {
    let budgets: [Budget]
    let commitments: [RecurringCommitment]
    let progresses: [BudgetProgress]
    let fxSnapshot: FXRateSnapshot?
    let salaryCycleFallbackBudgetIDs: Set<UUID>
}

enum BudgetProgressLoadError: Error {
    case invalidPeriodSequence(budgetID: UUID)
    case tooManyPeriods(budgetID: UUID)
}

/// Shared budget loading and calculation for every feature that presents
/// budget progress. Transaction filtering stays date-only so split parents
/// cannot be dropped before their effective split categories are resolved.
struct LoadBudgetProgresses: Sendable {
    private let budgetRepository: any BudgetRepository
    private let transactionRepository: any TransactionRepository
    private let annotationRepository: any TransactionAnnotationRepository
    private let splitRepository: any TransactionSplitRepository
    private let commitmentRepository: any RecurringCommitmentRepository
    private let fxRateProvider: any FXRateProvider
    private let transactionResolver = EffectiveTransactionResolver()
    private let periodResolver = BudgetPeriodResolver()

    init(
        budgetRepository: any BudgetRepository,
        transactionRepository: any TransactionRepository,
        annotationRepository: any TransactionAnnotationRepository,
        splitRepository: any TransactionSplitRepository,
        commitmentRepository: any RecurringCommitmentRepository,
        fxRateProvider: any FXRateProvider
    ) {
        self.budgetRepository = budgetRepository
        self.transactionRepository = transactionRepository
        self.annotationRepository = annotationRepository
        self.splitRepository = splitRepository
        self.commitmentRepository = commitmentRepository
        self.fxRateProvider = fxRateProvider
    }

    func execute(
        now: Date = Date(),
        calendar: Calendar = .current,
        baseCurrency: CurrencyCode,
        preferredFXSnapshot: FXRateSnapshot? = nil
    ) async throws -> BudgetProgressLoadResult {
        async let budgetsTask = budgetRepository.budgets()
        async let historyTask = budgetRepository.amountHistory(budgetID: nil)
        async let commitmentsTask = commitmentRepository.commitments()
        let (budgets, amountHistory, commitments) = try await (budgetsTask, historyTask, commitmentsTask)

        guard !budgets.isEmpty else {
            return BudgetProgressLoadResult(
                budgets: [],
                commitments: commitments,
                progresses: [],
                fxSnapshot: preferredFXSnapshot,
                salaryCycleFallbackBudgetIDs: []
            )
        }

        let calendarIntervals = Dictionary(uniqueKeysWithValues: budgets.compactMap { budget -> (UUID, DateInterval)? in
            guard case .calendarMonth(let startDay) = budget.periodPolicy else { return nil }
            return (
                budget.id,
                periodResolver.calendarMonthInterval(startDay: startDay, containing: now, calendar: calendar)
            )
        })

        let salaryHistoryStart = calendar.date(byAdding: .month, value: -48, to: now) ?? .distantPast
        var queryStart = calendarIntervals.values.map(\.start).min() ?? now
        if budgets.contains(where: \.isSalaryCycle) {
            queryStart = min(queryStart, salaryHistoryStart)
        }

        for budget in budgets where budget.rolloverPolicy == .accumulate {
            let earliestHistory = amountHistory
                .filter { $0.budgetID == budget.id }
                .map(\.periodStart)
                .min()
            let anchor = budget.createdAt ?? earliestHistory ?? calendarIntervals[budget.id]?.start ?? salaryHistoryStart
            queryStart = min(queryStart, anchor)
        }

        let initialQueryEnd = max(calendarIntervals.values.map(\.end).max() ?? now, now)
        var rawTransactions = try await readTransactions(from: queryStart, through: initialQueryEnd)
        var effectiveTransactions = transactionResolver.applying(
            annotations: try await annotations(for: Set(rawTransactions.map(\.id))),
            to: rawTransactions
        )

        var currentIntervals: [UUID: DateInterval] = [:]
        var fallbackBudgetIDs = Set<UUID>()
        for budget in budgets {
            do {
                currentIntervals[budget.id] = try periodResolver.interval(
                    for: budget,
                    containing: now,
                    calendar: calendar,
                    recurringCommitments: commitments,
                    transactions: effectiveTransactions
                )
            } catch {
                guard budget.isSalaryCycle else { throw error }
                currentIntervals[budget.id] = periodResolver.calendarMonthInterval(
                    startDay: 1,
                    containing: now,
                    calendar: calendar
                )
                fallbackBudgetIDs.insert(budget.id)
            }
        }

        let requiredEnd = currentIntervals.values.map(\.end).max() ?? initialQueryEnd
        if requiredEnd > initialQueryEnd {
            rawTransactions = try await readTransactions(from: queryStart, through: requiredEnd)
            effectiveTransactions = transactionResolver.applying(
                annotations: try await annotations(for: Set(rawTransactions.map(\.id))),
                to: rawTransactions
            )
            // An actual salary date inside the projected interval may have
            // replaced the schedule boundary after the expanded read.
            for budget in budgets where budget.isSalaryCycle && !fallbackBudgetIDs.contains(budget.id) {
                do {
                    currentIntervals[budget.id] = try periodResolver.interval(
                        for: budget,
                        containing: now,
                        calendar: calendar,
                        recurringCommitments: commitments,
                        transactions: effectiveTransactions
                    )
                } catch {
                    currentIntervals[budget.id] = periodResolver.calendarMonthInterval(
                        startDay: 1,
                        containing: now,
                        calendar: calendar
                    )
                    fallbackBudgetIDs.insert(budget.id)
                }
            }
        }

        let transactionIDs = Set(rawTransactions.map(\.id))
        let splitLines = try await splitLines(for: transactionIDs)
        let budgetCurrencies = Set(budgets.map(\.currency))
        let needsFX = budgetCurrencies.contains { $0 != baseCurrency }
            || effectiveTransactions.contains { budgetCurrencies != [$0.amount.currency] }
        let resolvedFX: FXRateSnapshot?
        if let preferredFXSnapshot {
            resolvedFX = preferredFXSnapshot
        } else if needsFX {
            resolvedFX = await fxRateProvider.snapshot()
        } else {
            resolvedFX = nil
        }
        let converter = resolvedFX.map { CurrencyConverter(eurPerUnit: $0.eurPerUnit) } ?? CurrencyConverter()
        let contributionCalculator = BudgetContributionCalculator(converter: converter)
        let rolloverCalculator = BudgetRolloverCalculator()

        var progresses: [BudgetProgress] = []
        for budget in budgets where budget.enabled {
            guard var interval = currentIntervals[budget.id] else { continue }
            let historyForBudget = amountHistory.filter { $0.budgetID == budget.id }
            let anchor = budget.createdAt
                ?? historyForBudget.map(\.periodStart).min()
                ?? interval.start

            var carry: Decimal = 0
            var excludedCurrencies = Set<CurrencyCode>()
            if budget.rolloverPolicy == .accumulate {
                do {
                    let priorIntervals = try priorIntervals(
                        for: budget,
                        before: interval.start,
                        anchor: anchor,
                        calendar: calendar,
                        commitments: commitments,
                        transactions: effectiveTransactions
                    )
                    for priorInterval in priorIntervals {
                        let periodTransactions = effectiveTransactions.filter {
                            $0.displayDate >= anchor && priorInterval.containsHalfOpen($0.displayDate)
                        }
                        let contributionResult = contributionCalculator.result(
                            budget: budget,
                            transactions: periodTransactions,
                            splitLines: splitLines,
                            period: priorInterval,
                            calendar: calendar
                        )
                        excludedCurrencies.formUnion(contributionResult.excludedCurrencies)
                        carry = rolloverCalculator.carriedOver(
                            budget: budget,
                            previousInterval: priorInterval,
                            previousSpent: contributionCalculator.total(contributionResult.contributions),
                            incomingCarry: carry,
                            amountHistory: historyForBudget
                        )
                    }
                } catch is BudgetPeriodResolverError where budget.isSalaryCycle {
                    // Salary-cycle accumulation must not mix salary and
                    // calendar periods. Fall back the entire budget to
                    // calendar months and expose that fallback to the UI.
                    fallbackBudgetIDs.insert(budget.id)
                    interval = periodResolver.calendarMonthInterval(
                        startDay: 1,
                        containing: now,
                        calendar: calendar
                    )
                    carry = 0
                    let priorIntervals = try priorIntervals(
                        for: budget,
                        before: interval.start,
                        anchor: anchor,
                        calendar: calendar,
                        commitments: commitments,
                        transactions: effectiveTransactions,
                        forceCalendarMonths: true
                    )
                    for priorInterval in priorIntervals {
                        let periodTransactions = effectiveTransactions.filter {
                            $0.displayDate >= anchor && priorInterval.containsHalfOpen($0.displayDate)
                        }
                        let contributionResult = contributionCalculator.result(
                            budget: budget,
                            transactions: periodTransactions,
                            splitLines: splitLines,
                            period: priorInterval,
                            calendar: calendar
                        )
                        excludedCurrencies.formUnion(contributionResult.excludedCurrencies)
                        carry = rolloverCalculator.carriedOver(
                            budget: budget,
                            previousInterval: priorInterval,
                            previousSpent: contributionCalculator.total(contributionResult.contributions),
                            incomingCarry: carry,
                            amountHistory: historyForBudget
                        )
                    }
                }
            }

            // `createdAt` bounds historical periods used for rollover. The
            // active period always reflects all activity in that period,
            // including spending from before the budget was configured.
            let periodTransactions = effectiveTransactions.filter {
                interval.containsHalfOpen($0.displayDate)
            }
            let currentResult = contributionCalculator.result(
                budget: budget,
                transactions: periodTransactions,
                splitLines: splitLines,
                period: interval,
                calendar: calendar
            )
            excludedCurrencies.formUnion(currentResult.excludedCurrencies)
            let limitOverride = historyForBudget
                .filter { $0.periodStart <= interval.start }
                .max { $0.periodStart < $1.periodStart }?
                .amount

            progresses.append(BudgetProgress(
                budget: budget,
                spent: contributionCalculator.total(currentResult.contributions),
                currency: budget.currency,
                period: interval,
                carriedOver: carry,
                limitOverride: limitOverride,
                excludedCurrencies: excludedCurrencies
            ))
        }

        progresses.sort {
            if $0.spent != $1.spent { return $0.spent > $1.spent }
            return $0.budget.name.localizedCaseInsensitiveCompare($1.budget.name) == .orderedAscending
        }

        return BudgetProgressLoadResult(
            budgets: budgets,
            commitments: commitments,
            progresses: progresses,
            fxSnapshot: resolvedFX,
            salaryCycleFallbackBudgetIDs: fallbackBudgetIDs
        )
    }

    private func readTransactions(from start: Date, through end: Date) async throws -> [Transaction] {
        let queryEnd = max(end, start.addingTimeInterval(1))
        var query = TransactionQuery()
        query.dateInterval = DateInterval(start: start, end: queryEnd)
        return try await transactionRepository.transactions(matching: query)
    }

    private func annotations(for transactionIDs: Set<UUID>) async throws -> [TransactionAnnotation] {
        guard !transactionIDs.isEmpty else { return [] }
        return try await annotationRepository.annotations(transactionIDs: transactionIDs)
    }

    private func splitLines(for transactionIDs: Set<UUID>) async throws -> [TransactionSplitLine] {
        guard !transactionIDs.isEmpty else { return [] }
        return try await splitRepository.splitLines(parentTransactionIDs: transactionIDs)
    }

    private func priorIntervals(
        for budget: Budget,
        before currentStart: Date,
        anchor: Date,
        calendar: Calendar,
        commitments: [RecurringCommitment],
        transactions: [Transaction],
        forceCalendarMonths: Bool = false
    ) throws -> [DateInterval] {
        var cursor = currentStart
        var intervals: [DateInterval] = []

        for _ in 0..<1_200 {
            let previous: DateInterval
            if forceCalendarMonths {
                previous = periodResolver.calendarMonthInterval(
                    startDay: 1,
                    containing: cursor.addingTimeInterval(-1),
                    calendar: calendar
                )
            } else {
                previous = try periodResolver.interval(
                    for: budget,
                    containing: cursor.addingTimeInterval(-1),
                    calendar: calendar,
                    recurringCommitments: commitments,
                    transactions: transactions
                )
            }
            guard previous.start < cursor else {
                throw BudgetProgressLoadError.invalidPeriodSequence(budgetID: budget.id)
            }
            guard previous.end > anchor else { return Array(intervals.reversed()) }
            intervals.append(previous)
            cursor = previous.start
            if previous.start < anchor { return Array(intervals.reversed()) }
        }

        throw BudgetProgressLoadError.tooManyPeriods(budgetID: budget.id)
    }
}
