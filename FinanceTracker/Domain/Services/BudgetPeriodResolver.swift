import Foundation

/// WP8: EINZIGE Periodenquelle für Budgets.
///
/// Unterstützt `calendarMonth(startDay:)` und `salaryCycle(incomeID:)`.
/// Consumer: Budget Overview (BudgetsModel), Budget Detail, Projection,
/// alle nutzen denselben Resolver statt lokaler Monats-Mathe.
///
/// Fehler-Semantik (§71): Ein Salary-Cycle-Budget ohne auffindbares
/// Income-Commitment oder mit weniger als zwei Zahlungen wirft einen
/// kontrollierten Domain-Error, kein stiller Kalendermonat-Fallback im
/// Resolver. Produktpolicy (dokumentiert): BudgetsModel rechnet solche
/// Budgets im Kalendermonat weiter, damit die Übersicht keine Daten
/// verliert; der Zustand ist über `salaryCycleUnavailable` sichtbar.
enum BudgetPeriodResolverError: Error, Equatable {
    case missingSalaryCommitment(incomeID: UUID)
    case insufficientSalaryHistory(incomeID: UUID)
}

struct BudgetPeriodResolver: Sendable {
    /// Intervall, das `date` enthält.
    ///
    /// - Parameters:
    ///   - recurringCommitments: Für Salary-Cycle-Budgets das Income-
    ///     Commitment (wird per ID gesucht).
    ///   - transactions: Historie für die Salary-Cycle-Matching-Basis.
    func interval(
        for budget: Budget,
        containing date: Date,
        calendar: Calendar,
        recurringCommitments: [RecurringCommitment] = [],
        transactions: [Transaction] = []
    ) throws -> DateInterval {
        switch budget.periodPolicy {
        case .calendarMonth(let startDay):
            return calendarMonthInterval(startDay: startDay, containing: date, calendar: calendar)
        case .salaryCycle(let incomeID):
            return try salaryCycleInterval(
                incomeID: incomeID,
                containing: date,
                calendar: calendar,
                recurringCommitments: recurringCommitments,
                transactions: transactions
            )
        }
    }

    /// Direkt vorheriges Intervall derselben Policy.
    func previousInterval(
        for budget: Budget,
        containing date: Date,
        calendar: Calendar,
        recurringCommitments: [RecurringCommitment] = [],
        transactions: [Transaction] = []
    ) throws -> DateInterval {
        let current = try interval(
            for: budget,
            containing: date,
            calendar: calendar,
            recurringCommitments: recurringCommitments,
            transactions: transactions
        )
        // Einen Tag vor dem aktuellen Intervallbeginn → das Vor-Intervall.
        let before = current.start.addingTimeInterval(-1)
        return try interval(
            for: budget,
            containing: before,
            calendar: calendar,
            recurringCommitments: recurringCommitments,
            transactions: transactions
        )
    }

    /// Verstrichene Tage (inkl. heute) und Gesamtdauer des Intervalls.
    func progress(
        in interval: DateInterval,
        now: Date,
        calendar: Calendar
    ) -> (elapsedDays: Int, totalDays: Int) {
        let total = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: interval.start), to: calendar.startOfDay(for: interval.end)
        ).day ?? 1
        let reference = min(now, interval.end)
        let elapsed = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: interval.start), to: calendar.startOfDay(for: reference)
        ).day ?? 0
        return (max(1, elapsed), max(1, total))
    }

    // MARK: - Policies

    /// Kalendermonat mit optionalem Starttag.
    ///
    /// startDay 1 → [Monatsanfang, Folgemonatsanfang).
    /// startDay 15 → z. B. [15.01., 15.02.): `date` am 10.02. liegt in der
    /// Periode, die am 15.01. beginnt.
    /// startDay > Monatstage (z. B. 31 im Februar) wird auf den letzten
    /// gültigen Tag geklemmt.
    func calendarMonthInterval(
        startDay: Int,
        containing date: Date,
        calendar: Calendar
    ) -> DateInterval {
        let clampedStartDay = max(1, startDay)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!

        if clampedStartDay <= 1 {
            let end = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            return DateInterval(start: monthStart, end: end)
        }

        let day = calendar.component(.day, from: date)
        let anchorMonthStart: Date
        let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 31
        if day >= min(clampedStartDay, daysInMonth) {
            anchorMonthStart = monthStart
        } else {
            anchorMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart)!
        }

        let start = clampedDate(yearMonthOf: anchorMonthStart, day: clampedStartDay, calendar: calendar)
        let end = clampedDate(yearMonthOf: anchorMonthStart, day: clampedStartDay, offsetMonths: 1, calendar: calendar)
        return DateInterval(start: start, end: end)
    }

    private func clampedDate(
        yearMonthOf reference: Date,
        day: Int,
        offsetMonths: Int = 0,
        calendar: Calendar
    ) -> Date {
        var base = reference
        if offsetMonths != 0 {
            base = calendar.date(byAdding: .month, value: offsetMonths, to: reference) ?? reference
        }
        var components = calendar.dateComponents([.year, .month], from: base)
        // Explizit auf den letzten gültigen Tag klemmen (31. im Februar →
        // 28./29.), statt Calendar den Overflow in den Folgemonat
        // normalisieren zu lassen (31.02 würde sonst 02.03.).
        if let range = calendar.range(of: .day, in: .month, for: base) {
            components.day = min(day, range.count)
        } else {
            components.day = day
        }
        return calendar.date(from: components)!
    }

    /// Salary-Cycle: der AKTIVE Gehalt-zu-Gehalt-Zeitraum.
    ///
    /// Produktsemantik:
    ///
    ///     cycleStart = letzte realisierte Gehaltszahlung ≤ referenceDate
    ///     cycleEnd   = nächster Gehaltstermin
    ///
    /// - Existiert bereits eine nächste reale Zahlung nach cycleStart,
    ///   ist diese cycleEnd (actual wins over schedule).
    /// - Sonst prognostiziert der RecurringScheduleService den nächsten
    ///   Termin aus dem Income-Commitment.
    /// - Eine einzige Zahlung genügt (§45): start = Zahlung, end =
    ///   prognostizierter Folgetermin, kein „insufficient history".
    ///
    /// - Keine Zahlung ≤ referenceDate oder kein planbarer Folgetermin →
    ///   `insufficientSalaryHistory`.
    /// - Income-Commitment fehlt → `missingSalaryCommitment`.
    private func salaryCycleInterval(
        incomeID: UUID,
        containing date: Date,
        calendar: Calendar,
        recurringCommitments: [RecurringCommitment],
        transactions: [Transaction]
    ) throws -> DateInterval {
        guard let incomeCommitment = recurringCommitments.first(where: { $0.id == incomeID }) else {
            throw BudgetPeriodResolverError.missingSalaryCommitment(incomeID: incomeID)
        }

        let matches = RecurringPaymentMatcher.matchingTransactions(
            for: incomeCommitment,
            in: transactions,
            calendar: calendar
        )
        .compactMap { $0.bookedAt ?? $0.authorizedAt }
        .sorted()

        guard let start = matches.last(where: { $0 <= date }) else {
            throw BudgetPeriodResolverError.insufficientSalaryHistory(incomeID: incomeID)
        }

        // Nächste REALE Zahlung schließt den Zyklus (actual wins), sonst
        // die Prognose aus dem Turnus.
        if let nextReal = matches.first(where: { $0 > start }) {
            return DateInterval(start: start, end: nextReal)
        }
        guard let projectedEnd = RecurringScheduleService().nextDate(
            after: start,
            cadence: incomeCommitment.cadence,
            calendar: calendar
        ) else {
            throw BudgetPeriodResolverError.insufficientSalaryHistory(incomeID: incomeID)
        }
        return DateInterval(start: start, end: projectedEnd)
    }
}
