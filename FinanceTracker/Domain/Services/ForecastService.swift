import Foundation

/// Forecast / „Noch verfügbar" (Roadmap #120–127, WP7).
///
/// Der Snapshot ist pure data: `daysRemaining` wird im Service aus dem
/// injizierten `now` berechnet (kein `Date()` in computed properties).
struct ForecastSnapshot: Sendable, Equatable {
    enum Confidence: String, Sendable {
        case high
        case medium
        case low
    }

    let period: DateInterval
    let confidence: Confidence

    let realizedIncome: Decimal
    let expectedIncome: Decimal

    /// Informative Aufteilung des bereits realisierten Verbrauchs.
    let realizedFixedCosts: Decimal
    let realizedVariableSpending: Decimal

    /// Offene (noch nicht bezahlte, geplante) Fixkosten, die NICHT von
    /// einem Budget abgedeckt sind (Roadmap #124: durch Budgets gedeckte
    /// Fixkosten zählt die Budget-Reservation, keine Doppelzählung).
    /// Occurrences-basiert: jährliche/quartalsweise Commitments zählen nur
    /// in Perioden, in denen sie tatsächlich fällig sind.
    let expectedFixedCosts: Decimal
    let remainingBudgetReservation: Decimal

    let plannedSavings: Decimal

    let availableAmount: Decimal
    let availablePerDay: Decimal

    /// Deterministisch aus dem injizierten `now` berechnet (WP7).
    let daysRemaining: Int

    /// Währungen aus Transaktionen, Budgetfortschritten oder Commitments,
    /// deren Beträge mangels passendem Kurs nicht in die Summen eingehen.
    let foreignCurrenciesExcluded: [CurrencyCode]
}

/// Deterministischer Forecast-Service (#122–125, WP7).
///
/// Formel (ohne Doppelzählung):
///   available = realizedIncome + expectedIncome
///             − realizedSpending (alles, inkl. bezahlter Fixkosten)
///             − openScheduledFixedCostsNotCoveredByBudgets
///               (occurrences-basiert: nur tatsächlich fällige Termine)
///             − remainingBudgetReservation
///
/// P2 Sparziele: Budgets mit targetAmount fließen über
/// remainingBudgetReservation ein (ihr Rest = Gespartes). `plannedSavings`
/// bleibt bewusst 0: eine zusätzliche Spar-Reservation würde doppelt
/// zählen. Sparziele brauchen keine eigene Forecast-Zeile.
///
/// Doppelzählungs-Policy (§63): Ein wiederkehrendes Commitment, dessen
/// Kategorie von einem aktivierten Budget abgedeckt ist, wird über die
/// Budget-Reservation (remaining) abgesichert: die offene Zahlung geht
/// NICHT zusätzlich in expectedFixedCosts ein. Bereits bezahlte
/// recurring-Zahlungen fließen ausschließlich über realizedSpending.
///
/// Currency Safety: Nur Commitments in `baseCurrency` fließen in die
/// Summen; Fremdwährungen werden gemeldet (`foreignCurrenciesExcluded`).
struct ForecastService: Sendable {
    private let scheduleService = RecurringScheduleService()
    private let occurrenceResolver = RecurringOccurrenceResolver()

    func forecast(
        period: DateInterval,
        transactions: [Transaction],
        budgets: [Budget],
        budgetProgresses: [BudgetProgress],
        commitments: [RecurringCommitment],
        explicitOccurrences: [RecurringOccurrence] = [],
        latestOccurrences: [UUID: Date] = [:],
        baseCurrency: CurrencyCode,
        calendar: Calendar = .current,
        now: Date = Date(),
        currencyConverter: CurrencyConverter = CurrencyConverter()
    ) -> ForecastSnapshot {
        PerfSignpost.measure("ForecastCompute") {
            forecastBody(
                period: period,
                transactions: transactions,
                budgets: budgets,
                budgetProgresses: budgetProgresses,
                commitments: commitments,
                explicitOccurrences: explicitOccurrences,
                latestOccurrences: latestOccurrences,
                baseCurrency: baseCurrency,
                calendar: calendar,
                now: now,
                currencyConverter: currencyConverter
            )
        }
    }

    private func forecastBody(
        period: DateInterval,
        transactions: [Transaction],
        budgets: [Budget],
        budgetProgresses: [BudgetProgress],
        commitments: [RecurringCommitment],
        explicitOccurrences: [RecurringOccurrence],
        latestOccurrences: [UUID: Date],
        baseCurrency: CurrencyCode,
        calendar: Calendar,
        now: Date,
        currencyConverter: CurrencyConverter
    ) -> ForecastSnapshot {
        let policy = CashflowPolicy.shared

        // „Realisiert" heißt: bis heute. Zukunftsbuchungen (z. B. Gehalt am
        // Monatsende) fließen über expectedIncome/expectedFixedCosts ein.
        let monthTxns = transactions.filter { txn in
            txn.status != .reversed
                && txn.status != .cancelled
                && period.containsHalfOpen(txn.displayDate)
                && txn.displayDate <= now
        }

        // 1) Realisierte Ströme
        var realizedIncome: Decimal = 0
        var realizedSpending: Decimal = 0
        var excludedCurrencies = Set<CurrencyCode>()
        for txn in monthTxns {
            guard !policy.isExcluded(txn) else { continue }
            switch policy.contribution(for: txn) {
            case .income(let delta):
                if let converted = currencyConverter.convert(
                    Money(amount: delta, currency: txn.amount.currency),
                    to: baseCurrency
                ) {
                    realizedIncome += converted.amount
                } else {
                    excludedCurrencies.insert(txn.amount.currency)
                }
            case .spending(let delta):
                if let converted = currencyConverter.convert(
                    Money(amount: delta, currency: txn.amount.currency),
                    to: baseCurrency
                ) {
                    realizedSpending += converted.amount
                } else {
                    excludedCurrencies.insert(txn.amount.currency)
                }
            case .neutral:
                break
            }
        }

        // 2) Scheduled Fixkosten (WP7): occurrences-basiert statt roher
        //    erwarteter Beträge. Jährliche/quartalsweise Commitments zählen
        //    nur, wenn in dieser Periode wirklich ein Termin liegt.
        let occurrencesByCommitment = Dictionary(
            grouping: explicitOccurrences,
            by: \.commitmentID
        )

        let activeExpenseCommitments = commitments.filter {
            $0.status == .active && $0.direction == .expense && $0.currency == baseCurrency
        }
        let activeIncomeCommitments = commitments.filter {
            $0.status == .active && $0.direction == .income && $0.currency == baseCurrency
        }

        let reservingProgresses = budgetProgresses.filter { progress in
            let budget = progress.budget
            return budget.enabled
                && budget.includeInForecast
                && budget.currency == progress.currency
                && progress.period.start == period.start
                && progress.period.end == period.end
        }
        for progress in reservingProgresses {
            excludedCurrencies.formUnion(progress.excludedCurrencies)
        }
        let convertedReservations: [(progress: BudgetProgress, amount: Decimal)] = reservingProgresses.compactMap { progress in
            guard let converted = currencyConverter.convert(
                Money(amount: progress.remaining, currency: progress.currency),
                to: baseCurrency
            ) else {
                excludedCurrencies.insert(progress.currency)
                return nil
            }
            return (progress, converted.amount)
        }

        var realizedFixed: Decimal = 0
        var openFixedNotInBudget: Decimal = 0

        for commitment in activeExpenseCommitments {
            let dueCount = scheduledOccurrenceCount(
                commitment: commitment,
                latestOccurrence: latestOccurrences[commitment.id],
                period: period,
                calendar: calendar
            )
            guard dueCount > 0 else { continue }

            // WP7 (§60): Dieselbe Occurrence-Resolution wie Fixkosten-UI.
            let resolution = occurrenceResolver.resolveOccurrences(
                commitment: commitment,
                explicitOccurrences: occurrencesByCommitment[commitment.id] ?? [],
                allTransactions: monthTxns,
                period: period,
                calendar: calendar,
                latestPaymentDate: latestOccurrences[commitment.id]
            )
            let paidCount = resolution.paidCount
            let coveredByBudget = commitment.categoryID.map { categoryID in
                reservingProgresses.contains { progress in
                    convertedReservations.contains { $0.progress.id == progress.id && $0.amount > 0 }
                        && progress.budget.accountIDs.isEmpty
                        && (progress.budget.categoryIDs.contains(categoryID)
                            || (progress.budget.isSalaryCycle && progress.budget.categoryIDs.isEmpty))
                }
            } ?? false

            let paidAmount = min(Decimal(paidCount), Decimal(dueCount)) * commitment.expectedAmount
            let openAmount = max(0, Decimal(dueCount - min(dueCount, paidCount))) * commitment.expectedAmount

            realizedFixed += paidAmount
            if !coveredByBudget {
                openFixedNotInBudget += openAmount
            }
            // Offen + Budget-abgedeckt → durch remainingBudgetReservation
            // abgedeckt (#124: keine Doppelzählung).
        }

        // 3) Budget-Reservation (#123): nur der REST, nie das volle Limit.
        let remainingBudgetReservation = nonOverlappingReservationTotal(convertedReservations)

        // 4) Erwartetes Einkommen (WP7): occurrences-basiert, geplante
        //    Einkommen der Periode minus bereits realisierter Anteil.
        var incomeDueInPeriod: Decimal = 0
        var incomeRealizedFromCommitments: Decimal = 0
        for commitment in activeIncomeCommitments {
            let dueCount = scheduledOccurrenceCount(
                commitment: commitment,
                latestOccurrence: latestOccurrences[commitment.id],
                period: period,
                calendar: calendar
            )
            guard dueCount > 0 else { continue }

            incomeDueInPeriod += Decimal(dueCount) * commitment.expectedAmount

            // WP7 (§60): Dieselbe Occurrence-Resolution wie Fixkosten-UI.
            let resolution = occurrenceResolver.resolveOccurrences(
                commitment: commitment,
                explicitOccurrences: occurrencesByCommitment[commitment.id] ?? [],
                allTransactions: monthTxns,
                period: period,
                calendar: calendar,
                latestPaymentDate: latestOccurrences[commitment.id]
            )
            incomeRealizedFromCommitments += min(Decimal(resolution.paidCount), Decimal(dueCount)) * commitment.expectedAmount
        }
        let expectedIncome = max(0, incomeDueInPeriod - incomeRealizedFromCommitments)

        // 5) Verfügbar (#122)
        let available = realizedIncome
            + expectedIncome
            - realizedSpending
            - openFixedNotInBudget
            - remainingBudgetReservation

        // 6) Rest-Tage inkl. heute, einmalig aus `now` berechnet (WP7).
        let daysLeft: Int
        if let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: period.end)
        ).day {
            daysLeft = max(1, days)
        } else {
            daysLeft = 1
        }

        let perDay = available / Decimal(daysLeft)

        // 7) Currency Safety (WP7): Fremdwährungs-Commitments gemeldet.
        excludedCurrencies.formUnion(
            commitments
                .filter { $0.status == .active && $0.currency != baseCurrency }
                .map(\.currency)
        )
        let foreignCurrencies = excludedCurrencies.sorted { $0.rawValue < $1.rawValue }

        return ForecastSnapshot(
            period: period,
            confidence: confidence(
                hasBudgets: !budgets.isEmpty,
                realizedIncome: realizedIncome,
                commitments: commitments
            ),
            realizedIncome: realizedIncome,
            expectedIncome: expectedIncome,
            realizedFixedCosts: realizedFixed,
            realizedVariableSpending: realizedSpending - realizedFixed,
            expectedFixedCosts: openFixedNotInBudget,
            remainingBudgetReservation: remainingBudgetReservation,
            plannedSavings: 0,
            availableAmount: available,
            availablePerDay: perDay,
            daysRemaining: daysLeft,
            foreignCurrenciesExcluded: foreignCurrencies
        )
    }

    /// Budgets mit überlappenden Kategorie-/Kontoscopes reservieren
    /// denselben Ausgabenumschlag. Pro zusammenhängender Gruppe zählt daher
    /// nur der größte Rest; unabhängige Scopes werden addiert.
    private func nonOverlappingReservationTotal(
        _ reservations: [(progress: BudgetProgress, amount: Decimal)]
    ) -> Decimal {
        var remainingIndices = Set(reservations.indices)
        var total: Decimal = 0

        while let seed = remainingIndices.first {
            remainingIndices.remove(seed)
            var component = [seed]
            var frontier = [seed]

            while let current = frontier.popLast() {
                let overlaps = remainingIndices.filter { candidate in
                    scopesOverlap(reservations[current].progress.budget, reservations[candidate].progress.budget)
                }
                for index in overlaps {
                    remainingIndices.remove(index)
                    component.append(index)
                    frontier.append(index)
                }
            }

            total += component.map { reservations[$0].amount }.max() ?? 0
        }
        return total
    }

    private func scopesOverlap(_ lhs: Budget, _ rhs: Budget) -> Bool {
        let lhsAllCategories = lhs.isSalaryCycle && lhs.categoryIDs.isEmpty
        let rhsAllCategories = rhs.isSalaryCycle && rhs.categoryIDs.isEmpty
        let categoriesOverlap = lhsAllCategories || rhsAllCategories
            || !lhs.categoryIDs.isDisjoint(with: rhs.categoryIDs)

        let accountsOverlap = lhs.accountIDs.isEmpty || rhs.accountIDs.isEmpty
            || !lhs.accountIDs.isDisjoint(with: rhs.accountIDs)
        return categoriesOverlap && accountsOverlap
    }

    /// Anzahl geplanter Termine im Zeitraum. Seed: gespeicherte Planung
    /// oder der Termin nach der letzten Zahlung; ohne beides nicht
    /// planbar → 0.
    private func scheduledOccurrenceCount(
        commitment: RecurringCommitment,
        latestOccurrence: Date?,
        period: DateInterval,
        calendar: Calendar
    ) -> Int {
        var planned = commitment
        if planned.nextExpectedDate == nil {
            guard let latestOccurrence else { return 0 }
            planned.nextExpectedDate = scheduleService.seed(
                afterLatestPayment: latestOccurrence,
                in: period,
                cadence: planned.cadence,
                calendar: calendar
            ) ?? latestOccurrence
        }
        return scheduleService.occurrences(
            for: planned,
            in: period,
            calendar: calendar
        ).count
    }

    /// Roadmap #125: Keine pseudo-präzise Zahl ohne Datenbasis.
    /// Signale: (a) aktives Commitment, (b) aktives Budget, (c) realisiertes
    /// Einkommen. 3 Signale = hoch, 2 = mittel, ≤1 = niedrig.
    ///
    /// V1-Note: Die Confidence ist bewusst simpel (Datenbasis-Bewertung,
    /// keine Per-Commitment-Güte). Der Dashboard-Hero zeigt „Noch verfügbar"
    /// nur bei ausreichender Confidence.
    private func confidence(
        hasBudgets: Bool,
        realizedIncome: Decimal,
        commitments: [RecurringCommitment]
    ) -> ForecastSnapshot.Confidence {
        var signals = 0
        if commitments.contains(where: { $0.status == .active }) { signals += 1 }
        if hasBudgets { signals += 1 }
        if realizedIncome > 0 { signals += 1 }

        switch signals {
        case 3: return .high
        case 2: return .medium
        default: return .low
        }
    }
}
