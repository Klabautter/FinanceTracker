import Foundation

/// WP6: Fachlich korrekte Fixkosten-Summen.
///
/// Zwei getrennte Summary-Semantiken:
/// 1. **Monthly Equivalent** („Ø monatlich“): Normalisierung des Turnus auf
///    einen Monat (weekly → ×52/12, monthly → ×1, quarterly → ÷3, yearly →
///    ÷12) über `RecurringScheduleService.monthlyEquivalentDivisor`.
/// 2. **Due In Period** („Fällig in dieser Periode“): tatsächliche geplante
///    Termine im Zeitraum via `RecurringScheduleService.occurrences(in:)`.
///
/// Currency Safety: Nur Base-Currency-Commitments fließen in die
/// Basis-Summen. Fremdwährungen bleiben separat (kein stilles Mischen).
/// Das Label der UI muss immer klarstellen, welche Semantik gezeigt wird.
struct RecurringSummaryCalculator: Sendable {
    struct ForeignBucket: Sendable, Equatable {
        let currency: CurrencyCode
        let monthlyEquivalent: Decimal
        let dueInPeriod: Decimal
    }

    struct Summary: Sendable, Equatable {
        /// Base currency: Ausgaben „Ø monatlich“.
        let expenseMonthlyEquivalent: Decimal
        /// Base currency: Ausgaben, die im Zeitraum tatsächlich fällig sind.
        let expenseDueInPeriod: Decimal
        /// Base currency: fällig im Zeitraum und noch nicht bezahlt.
        let openDueInPeriod: Decimal
        /// Base currency: wiederkehrende Einnahmen „Ø monatlich“.
        let incomeMonthlyEquivalent: Decimal
        /// Base currency: Einnahmen fällig im Zeitraum.
        let incomeDueInPeriod: Decimal
        /// Fremdwährungen sind bewusst NICHT in den Basis-Summen.
        let foreignExpense: [ForeignBucket]
        let foreignIncome: [ForeignBucket]
        /// Währungen mit Commitments ohne planbaren Termin (kein
        /// nextExpectedDate, keine letzte Zahlung), nicht als fällig
        /// planbar.
        let currenciesWithoutPlan: [CurrencyCode]

        var foreignCurrencies: [CurrencyCode] {
            Set(
                foreignExpense.map(\.currency)
                    + foreignIncome.map(\.currency)
                    + currenciesWithoutPlan
            ).sorted { $0.rawValue < $1.rawValue }
        }
    }

    private let scheduleService = RecurringScheduleService()

    /// Betrag, der im Zeitraum fällig ist (Turnus × geplante Vorkommen).
    /// Ohne planbaren Termin (kein nextExpectedDate und keine letzte
    /// Zahlung) ist nichts planbar → 0.
    func dueAmount(
        for commitment: RecurringCommitment,
        latestOccurrence: Date?,
        in period: DateInterval,
        calendar: Calendar
    ) -> Decimal {
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
        let occurrences = scheduleService.occurrences(
            for: planned,
            in: period,
            calendar: calendar
        ).count
        return planned.expectedAmount * Decimal(occurrences)
    }

    /// „Ø monatlich“ eines Commitments (Turnus-normalisiert).
    func monthlyEquivalent(for commitment: RecurringCommitment) -> Decimal {
        let divisor = scheduleService.monthlyEquivalentDivisor(cadence: commitment.cadence)
        guard divisor != 0 else { return 0 }
        return commitment.expectedAmount / divisor
    }

    /// Aggregierte Summary über alle Commitments.
    ///
    /// Nur Commitments in `baseCurrency` fließen in die Basis-Summen;
    /// Fremdwährungen erscheinen in separaten Buckets.
    ///
    /// WP7 (§59): Die Paid/Open-Semantik kommt aus den Occurrence-
    /// Resolutions (geplante Vorkommen), nicht aus einem groben
    /// Commitment-Level-Paid-Flag: wöchentliche Commitments können
    /// teilweise bezahlt sein.
    ///
    /// - Parameters:
    ///   - latestOccurrences: Datum der letzten gültigen Zahlung pro
    ///     Commitment (laut RecurringOccurrenceResolver): dient als
    ///     Plan-Seed, wenn kein nextExpectedDate gespeichert ist.
    ///   - resolutions: Occurrence-Resolution pro Commitment für `period`.
    func summary(
        commitments: [RecurringCommitment],
        latestOccurrences: [UUID: Date],
        resolutions: [UUID: RecurringOccurrenceResolution],
        period: DateInterval,
        baseCurrency: CurrencyCode,
        calendar: Calendar
    ) -> Summary {
        var expenseMonthly: Decimal = 0
        var expenseDue: Decimal = 0
        var openDue: Decimal = 0
        var incomeMonthly: Decimal = 0
        var incomeDue: Decimal = 0

        var foreignExpenseMonthly: [CurrencyCode: Decimal] = [:]
        var foreignExpenseDue: [CurrencyCode: Decimal] = [:]
        var foreignIncomeMonthly: [CurrencyCode: Decimal] = [:]
        var foreignIncomeDue: [CurrencyCode: Decimal] = [:]
        var withoutPlan: Set<CurrencyCode> = []

        for commitment in commitments where commitment.status == .active {
            let monthly = monthlyEquivalent(for: commitment)
            let resolution = resolutions[commitment.id]
            // Fällig/offen aus den geplanten Vorkommen; ohne Resolution
            // greift der Legacy-Pfad über die Schedule-Berechnung.
            let due = resolution?.dueAmount ?? dueAmount(
                for: commitment,
                latestOccurrence: latestOccurrences[commitment.id],
                in: period,
                calendar: calendar
            )
            let open = resolution?.openAmount ?? due
            let isPlanable = commitment.nextExpectedDate != nil
                || latestOccurrences[commitment.id] != nil
                || (resolution?.scheduled.isEmpty == false)

            if !isPlanable {
                withoutPlan.insert(commitment.currency)
            }

            switch (commitment.direction, commitment.currency == baseCurrency) {
            case (.expense, true):
                expenseMonthly += monthly
                expenseDue += due
                openDue += open
            case (.expense, false):
                foreignExpenseMonthly[commitment.currency, default: 0] += monthly
                foreignExpenseDue[commitment.currency, default: 0] += due
            case (.income, true):
                incomeMonthly += monthly
                incomeDue += due
            case (.income, false):
                foreignIncomeMonthly[commitment.currency, default: 0] += monthly
                foreignIncomeDue[commitment.currency, default: 0] += due
            }
        }

        return Summary(
            expenseMonthlyEquivalent: expenseMonthly,
            expenseDueInPeriod: expenseDue,
            openDueInPeriod: openDue,
            incomeMonthlyEquivalent: incomeMonthly,
            incomeDueInPeriod: incomeDue,
            foreignExpense: buckets(foreignExpenseMonthly, due: foreignExpenseDue),
            foreignIncome: buckets(foreignIncomeMonthly, due: foreignIncomeDue),
            currenciesWithoutPlan: withoutPlan.sorted { $0.rawValue < $1.rawValue }
        )
    }

    private func buckets(
        _ monthly: [CurrencyCode: Decimal],
        due: [CurrencyCode: Decimal]
    ) -> [ForeignBucket] {
        monthly
            .map { currency, amount in
                ForeignBucket(
                    currency: currency,
                    monthlyEquivalent: amount,
                    dueInPeriod: due[currency] ?? 0
                )
            }
            .sorted { $0.currency.rawValue < $1.currency.rawValue }
    }
}
