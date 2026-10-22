import Foundation
import Testing

@testable import FinanceTracker

/// WP7: Forecast-Tests mit fest injiziertem `now`/`calendar`
/// deterministisch, keine `Date()`-Abhängigkeit.
struct ForecastServiceTests {
    private let service = ForecastService()

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    /// Fester Bezugszeitpunkt: 15.03.2026, 12:00.
    private let now: Date = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12))!
    }()

    /// März 2026.
    private var period: DateInterval {
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    private func expenseTxn(
        _ amount: Decimal,
        merchant: String,
        categoryID: UUID? = nil,
        bookedAt: Date? = nil,
        currency: CurrencyCode = .eur
    ) -> Transaction {
        var txn = Transaction(
            accountID: UUID(),
            source: .demo,
            externalID: UUID().uuidString,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -amount, currency: currency),
            bookedAt: bookedAt ?? now,
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
        txn.categoryID = categoryID
        return txn
    }

    private func incomeTxn(_ amount: Decimal, merchant: String, bookedAt: Date? = nil) -> Transaction {
        Transaction(
            accountID: UUID(),
            source: .demo,
            externalID: UUID().uuidString,
            status: .booked,
            kind: .income,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: bookedAt ?? now,
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
    }

    private func commitment(
        name: String,
        direction: RecurringCommitment.Direction = .expense,
        cadence: RecurringCommitment.Cadence = .monthly,
        amount: Decimal,
        currency: CurrencyCode = .eur,
        categoryID: UUID? = nil,
        nextExpected: Date? = nil
    ) -> RecurringCommitment {
        RecurringCommitment(
            name: name,
            merchantKey: name.uppercased(),
            direction: direction,
            cadence: cadence,
            amountPolicy: .fixed,
            expectedAmount: amount,
            currency: currency,
            categoryID: categoryID,
            nextExpectedDate: nextExpected,
            status: .active
        )
    }

    private func date(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9))!
    }

    // MARK: - Basis

    @Test("Formel-Basis: Einkommen minus Ausgaben, ohne Budgets/Commitments")
    func baseFormula() {
        let snapshot = service.forecast(
            period: period,
            transactions: [
                incomeTxn(Decimal(string: "2850.00")!, merchant: "Gehalt", bookedAt: date(3, 5)),
                expenseTxn(Decimal(string: "1000.00")!, merchant: "Miete", bookedAt: date(3, 3)),
                expenseTxn(Decimal(string: "500.00")!, merchant: "Lebensmittel", bookedAt: date(3, 10))
            ],
            budgets: [],
            budgetProgresses: [],
            commitments: [],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.availableAmount == Decimal(string: "1350.00")!)
        #expect(snapshot.realizedVariableSpending == Decimal(string: "1500.00")!)
        #expect(snapshot.confidence == .low) // kein Commitment, kein Budget, Einkommen realisiert
    }

    @Test("Budget-Reservation zählt nur den Rest (#123)")
    func budgetReservation() {
        let catID = UUID()
        let budget = Budget(name: "Lebensmittel", amount: 400, categoryIDs: [catID])
        let progress = BudgetProgress(budget: budget, spent: Decimal(string: "150.00")!, currency: .eur, period: period)

        let snapshot = service.forecast(
            period: period,
            transactions: [expenseTxn(Decimal(string: "150.00")!, merchant: "Lebensmittel", categoryID: catID, bookedAt: date(3, 8))],
            budgets: [budget],
            budgetProgresses: [progress],
            commitments: [],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.remainingBudgetReservation == Decimal(string: "250.00")!)
        #expect(snapshot.availableAmount == Decimal(string: "-400.00")!)
    }

    // MARK: - Scheduled Occurrences (WP7)

    @Test("Monthly recurring fällig in der Periode → offene Fixkosten")
    func monthlyRecurringDueInPeriod() {
        let rent = commitment(name: "Miete", amount: 900, nextExpected: date(3, 5))

        let snapshot = service.forecast(
            period: period,
            transactions: [],
            budgets: [],
            budgetProgresses: [],
            commitments: [rent],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )
        #expect(snapshot.expectedFixedCosts == 900)
        #expect(snapshot.availableAmount == Decimal(string: "-900.00")!)
    }

    @Test("Yearly recurring NICHT fällig → keine Fixkosten in dieser Periode")
    func yearlyRecurringNotDue() {
        let insurance = commitment(name: "Versicherung", cadence: .yearly, amount: 1200, nextExpected: date(12, 31))

        let snapshot = service.forecast(
            period: period,
            transactions: [],
            budgets: [],
            budgetProgresses: [],
            commitments: [insurance],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )
        #expect(snapshot.expectedFixedCosts == 0)
        #expect(snapshot.availableAmount == 0)
    }

    @Test("Quarterly recurring fällig in dieser Periode")
    func quarterlyDueInPeriod() {
        let fee = commitment(name: "Gebühr", cadence: .quarterly, amount: 300, nextExpected: date(3, 10))

        let snapshot = service.forecast(
            period: period,
            transactions: [],
            budgets: [],
            budgetProgresses: [],
            commitments: [fee],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )
        #expect(snapshot.expectedFixedCosts == 300)
    }

    @Test("Salary income fällig (noch nicht gebucht) → expectedIncome")
    func salaryIncomeDue() {
        let salary = commitment(
            name: "Gehalt",
            direction: .income,
            amount: Decimal(string: "2850.00")!,
            nextExpected: date(3, 28) // nach now (15.03.)
        )

        let snapshot = service.forecast(
            period: period,
            transactions: [],
            budgets: [],
            budgetProgresses: [],
            commitments: [salary],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )
        #expect(snapshot.realizedIncome == 0)
        #expect(snapshot.expectedIncome == Decimal(string: "2850.00")!)
    }

    @Test("Gehalt bereits realisiert → expectedIncome 0 (keine Doppelzählung)")
    func salaryRealized() {
        let salary = commitment(
            name: "Gehalt",
            direction: .income,
            amount: Decimal(string: "2850.00")!,
            nextExpected: date(3, 28)
        )

        let snapshot = service.forecast(
            period: period,
            transactions: [incomeTxn(Decimal(string: "2850.00")!, merchant: "GEHALT", bookedAt: date(3, 10))],
            budgets: [],
            budgetProgresses: [],
            commitments: [salary],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )
        #expect(snapshot.realizedIncome == Decimal(string: "2850.00")!)
        #expect(snapshot.expectedIncome == 0)
        #expect(snapshot.confidence == .medium) // 2 Signale: Commitment + realisiertes Einkommen
    }

    @Test("Bezahlte Fixkosten fließen über realizedSpending, offen sinkt")
    func paidFixedCosts() {
        let rent = commitment(name: "Miete", amount: 900, nextExpected: date(3, 5))

        let snapshot = service.forecast(
            period: period,
            transactions: [expenseTxn(Decimal(string: "900.00")!, merchant: "MIETE MUSTERSTRASSE", bookedAt: date(3, 3))],
            budgets: [],
            budgetProgresses: [],
            commitments: [rent],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )
        #expect(snapshot.expectedFixedCosts == 0)
        #expect(snapshot.realizedFixedCosts == 900)
        #expect(snapshot.availableAmount == Decimal(string: "-900.00")!)
    }

    @Test("Zahlung im Zeitraum als letzte Zahlung übergeben → nicht zusätzlich offen")
    func paidFixedCostsWithLatestOccurrenceInPeriod() {
        // Der Dashboard-Pfad übergibt die letzte Zahlung (hier: im laufenden
        // Monat). Sie darf den Plan nicht auf den Folgetermin schieben
        // sonst gilt der bezahlte Termin als offen und wird doppelt abgezogen.
        let rent = commitment(name: "Miete", amount: 900, nextExpected: date(3, 1))
        let payment = expenseTxn(Decimal(string: "900.00")!, merchant: "MIETE MUSTERSTRASSE", bookedAt: date(3, 1))

        let snapshot = service.forecast(
            period: period,
            transactions: [payment],
            budgets: [],
            budgetProgresses: [],
            commitments: [rent],
            latestOccurrences: [rent.id: date(3, 1)],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )
        #expect(snapshot.expectedFixedCosts == 0)
        #expect(snapshot.realizedFixedCosts == 900)
        #expect(snapshot.availableAmount == Decimal(string: "-900.00")!)
    }

    @Test("Doppelzählung: recurring + Budget in gleicher Kategorie (#124/#63)")
    func budgetOverlapNoDoubleCount() {
        let budgetedCat = UUID()
        let budget = Budget(name: "Abos", amount: 30, categoryIDs: [budgetedCat])
        let progress = BudgetProgress(budget: budget, spent: 0, currency: .eur, period: period)

        let netflix = commitment(
            name: "Netflix",
            amount: Decimal(string: "13.99")!,
            categoryID: budgetedCat,
            nextExpected: date(3, 20)
        )
        let rent = commitment(name: "Miete", amount: 900, nextExpected: date(3, 5))

        let snapshot = service.forecast(
            period: period,
            transactions: [],
            budgets: [budget],
            budgetProgresses: [progress],
            commitments: [netflix, rent],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )

        // Netflix budget-abgedeckt → nur Budget-Reservation; Miete offen
        // (keine bezahlte Transaktion) und nicht budget-abgedeckt.
        #expect(snapshot.remainingBudgetReservation == 30)
        #expect(snapshot.expectedFixedCosts == 900)
        // available = 0 − 900 (Miete offen) − 30 (Budget-Rest)
        #expect(snapshot.availableAmount == Decimal(string: "-930.00")!)
    }

    @Test("Forecast übernimmt Refunds, Analytics-Ausschlüsse und FX-konvertierte Zahlungen")
    func realizedCashflowUsesEffectiveSignedContributions() {
        var refund = expenseTxn(40, merchant: "Rückerstattung", bookedAt: date(3, 10))
        refund.kind = .refund
        refund.amount = Money(amount: 40, currency: .eur)

        var excluded = expenseTxn(60, merchant: "Ausgeschlossen", bookedAt: date(3, 11))
        excluded.excludedFromAnalytics = true

        let convertedExpense = expenseTxn(10, merchant: "USD Einkauf", bookedAt: date(3, 12), currency: .usd)
        let converter = CurrencyConverter(eurPerUnit: [.usd: Decimal(string: "0.92")!])

        let snapshot = service.forecast(
            period: period,
            transactions: [
                expenseTxn(30, merchant: "Einkauf", bookedAt: date(3, 9)),
                refund,
                excluded,
                convertedExpense
            ],
            budgets: [],
            budgetProgresses: [],
            commitments: [],
            baseCurrency: .eur,
            calendar: calendar,
            now: now,
            currencyConverter: converter
        )

        #expect(snapshot.realizedVariableSpending == Decimal(string: "-0.80")!)
        #expect(snapshot.availableAmount == Decimal(string: "0.80")!)
        #expect(snapshot.foreignCurrenciesExcluded.isEmpty)
    }

    @Test("Transaktionen ohne FX-Kurs werden sichtbar als unvollständig gemeldet")
    func foreignTransactionsWithoutRateAreReported() {
        let snapshot = service.forecast(
            period: period,
            transactions: [expenseTxn(25, merchant: "GBP Einkauf", bookedAt: date(3, 9), currency: .gbp)],
            budgets: [],
            budgetProgresses: [],
            commitments: [],
            baseCurrency: .eur,
            calendar: calendar,
            now: now,
            currencyConverter: CurrencyConverter(eurPerUnit: [:])
        )

        #expect(snapshot.realizedVariableSpending == 0)
        #expect(snapshot.foreignCurrenciesExcluded == [CurrencyCode.gbp])
    }

    @Test("Budget-Reservation berücksichtigt Aktivierung, Forecast-Flag und Periode")
    func budgetReservationRequiresActiveForecastBudgetInPeriod() {
        let included = Budget(name: "Aktuell", amount: 40)
        let disabled = Budget(name: "Deaktiviert", amount: 80, enabled: false)
        let excludedFromForecast = Budget(name: "Nicht im Forecast", amount: 120, includeInForecast: false)
        let expired = Budget(name: "Vorperiode", amount: 70)
        let previousPeriod = DateInterval(start: date(2, 1), end: date(3, 1))

        let snapshot = service.forecast(
            period: period,
            transactions: [],
            budgets: [included, disabled, excludedFromForecast, expired],
            budgetProgresses: [
                BudgetProgress(budget: included, spent: 0, currency: .eur, period: period),
                BudgetProgress(budget: disabled, spent: 0, currency: .eur, period: period),
                BudgetProgress(budget: excludedFromForecast, spent: 0, currency: .eur, period: period),
                BudgetProgress(budget: expired, spent: 0, currency: .eur, period: previousPeriod)
            ],
            commitments: [],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.remainingBudgetReservation == 40)
    }

    @Test("Überlappende Budget-Scopes reservieren nicht denselben Betrag doppelt")
    func overlappingBudgetsReserveOneSharedEnvelope() {
        let categoryA = UUID()
        let categoryB = UUID()
        let categoryC = UUID()
        let narrow = Budget(name: "A", amount: 80, categoryIDs: [categoryA])
        let overlapping = Budget(name: "A und B", amount: 120, categoryIDs: [categoryA, categoryB])
        let separate = Budget(name: "C", amount: 40, categoryIDs: [categoryC])

        let snapshot = service.forecast(
            period: period,
            transactions: [],
            budgets: [narrow, overlapping, separate],
            budgetProgresses: [
                BudgetProgress(budget: narrow, spent: 0, currency: .eur, period: period),
                BudgetProgress(budget: overlapping, spent: 0, currency: .eur, period: period),
                BudgetProgress(budget: separate, spent: 0, currency: .eur, period: period)
            ],
            commitments: [],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.remainingBudgetReservation == 160)
    }

    @Test("Fixkosten gelten nur bei reservierendem Budget derselben Periode und ohne unbekannten Kontobezug als gedeckt")
    func fixedCostCoverageRequiresMatchingForecastScope() {
        let categoryID = UUID()
        let commitment = commitment(
            name: "Miete",
            amount: 60,
            categoryID: categoryID,
            nextExpected: date(3, 20)
        )
        let notForecasted = Budget(
            name: "Nicht reserviert",
            amount: 100,
            categoryIDs: [categoryID],
            includeInForecast: false
        )
        let scopedToUnknownAccount = Budget(
            name: "Anderes Konto",
            amount: 75,
            categoryIDs: [categoryID],
            accountIDs: [UUID()]
        )
        let priorPeriodBudget = Budget(name: "Vorperiode", amount: 90, categoryIDs: [categoryID])

        let snapshot = service.forecast(
            period: period,
            transactions: [],
            budgets: [notForecasted, scopedToUnknownAccount, priorPeriodBudget],
            budgetProgresses: [
                BudgetProgress(budget: notForecasted, spent: 0, currency: .eur, period: period),
                BudgetProgress(budget: scopedToUnknownAccount, spent: 0, currency: .eur, period: period),
                BudgetProgress(
                    budget: priorPeriodBudget,
                    spent: 0,
                    currency: .eur,
                    period: DateInterval(start: date(2, 1), end: date(3, 1))
                )
            ],
            commitments: [commitment],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.expectedFixedCosts == 60)
        #expect(snapshot.remainingBudgetReservation == 75)
    }

    @Test("Fixkosten werden durch ein Budget ohne Rest nicht als gedeckt markiert")
    func fixedCostCoverageRequiresPositiveRemainingReservation() {
        let categoryID = UUID()
        let commitment = commitment(
            name: "Miete",
            amount: 60,
            categoryID: categoryID,
            nextExpected: date(3, 20)
        )
        let fullySpentBudget = Budget(name: "Voll ausgeschöpft", amount: 60, categoryIDs: [categoryID])

        let snapshot = service.forecast(
            period: period,
            transactions: [],
            budgets: [fullySpentBudget],
            budgetProgresses: [
                BudgetProgress(budget: fullySpentBudget, spent: 60, currency: .eur, period: period)
            ],
            commitments: [commitment],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.remainingBudgetReservation == 0)
        #expect(snapshot.expectedFixedCosts == 60)
    }

    @Test("Fremdwährungs-Commitments sind ausgeschlossen und gemeldet")
    func foreignRecurringExcluded() {
        let usdAbo = commitment(
            name: "US Abo",
            amount: 20,
            currency: .usd,
            nextExpected: date(3, 12)
        )
        let eurRent = commitment(name: "Miete", amount: 900, nextExpected: date(3, 5))

        let snapshot = service.forecast(
            period: period,
            transactions: [],
            budgets: [],
            budgetProgresses: [],
            commitments: [usdAbo, eurRent],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )
        // Kein Cross-Currency-Mix: 900 + 20 ≠ 920.
        #expect(snapshot.expectedFixedCosts == 900)
        #expect(snapshot.foreignCurrenciesExcluded == [.usd])
    }

    @Test("Explizite Zuordnung schlägt Merchant-/Betrags-Mismatch")
    func explicitOccurrenceWins() {
        let manual = commitment(name: "Verein", amount: 25, nextExpected: date(3, 8))
        let mismatched = expenseTxn(Decimal(string: "30.00")!, merchant: "SPORTVEREIN", bookedAt: date(3, 9))
        let occurrence = RecurringOccurrence(commitmentID: manual.id, transactionID: mismatched.id)

        let snapshot = service.forecast(
            period: period,
            transactions: [mismatched],
            budgets: [],
            budgetProgresses: [],
            commitments: [manual],
            explicitOccurrences: [occurrence],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )
        #expect(snapshot.expectedFixedCosts == 0)
        #expect(snapshot.realizedFixedCosts == 25)
    }

    @Test("Ohne planbaren Termin (kein Plan, keine Zahlung): nicht fällig")
    func unplannedCommitmentNotDue() {
        let manual = commitment(name: "Manuell", amount: 50, nextExpected: nil)

        let snapshot = service.forecast(
            period: period,
            transactions: [],
            budgets: [],
            budgetProgresses: [],
            commitments: [manual],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )
        #expect(snapshot.expectedFixedCosts == 0)
    }

    // MARK: - Determinismus (§62)

    @Test("daysRemaining deterministisch aus injiziertem now")
    func daysRemainingDeterministic() {
        let rent = commitment(name: "Miete", amount: 900, nextExpected: date(3, 5))
        let input = { (referenceNow: Date) in
            self.service.forecast(
                period: self.period,
                transactions: [],
                budgets: [],
                budgetProgresses: [],
                commitments: [rent],
                baseCurrency: .eur,
                calendar: self.calendar,
                now: referenceNow
            )
        }

        let midMonth = input(date(3, 15))
        let lateMonth = input(date(3, 30))

        // 01.04. − 15.03. = 17 Tage; 01.04. − 30.03. = 2 Tage
        #expect(midMonth.daysRemaining == 17)
        #expect(lateMonth.daysRemaining == 2)
        // Gleicher now → gleicher Snapshot (pure data).
        #expect(input(date(3, 15)) == midMonth)
    }

    @Test("availablePerDay = verfügbar / verbleibende Tage inkl. heute")
    func perDay() {
        let snapshot = service.forecast(
            period: period,
            transactions: [incomeTxn(Decimal(300), merchant: "X", bookedAt: date(3, 2))],
            budgets: [],
            budgetProgresses: [],
            commitments: [],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )
        #expect(snapshot.availableAmount == Decimal(300))
        #expect(snapshot.availablePerDay == Decimal(300) / Decimal(snapshot.daysRemaining))
        #expect(snapshot.daysRemaining == 17)
    }
}
