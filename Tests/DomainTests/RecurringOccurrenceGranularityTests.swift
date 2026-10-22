import Foundation
import Testing

@testable import FinanceTracker

/// WP7 (§61): Occurrence-Level-Granularität für wiederkehrende Zahlungen.
/// Wöchentliche Commitments können TEILWEISE bezahlt sein; jede echte
/// Transaktion bezahlt höchstens ein geplantes Vorkommen; explizite
/// Nutzer-Zuordnung gewinnt.
@Suite("RecurringOccurrenceGranularity")
struct RecurringOccurrenceGranularityTests {

    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func monthInterval(year: Int, month: Int) -> DateInterval {
        let start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    private func commitment(
        name: String = "Netflix",
        cadence: RecurringCommitment.Cadence,
        amount: Decimal,
        currency: CurrencyCode = .eur,
        nextExpected: Date?
    ) -> RecurringCommitment {
        RecurringCommitment(
            name: name,
            merchantKey: name.uppercased(),
            direction: .expense,
            cadence: cadence,
            amountPolicy: .fixed,
            expectedAmount: amount,
            currency: currency,
            nextExpectedDate: nextExpected,
            status: .active
        )
    }

    private func payment(
        on date: Date,
        merchant: String = "Netflix",
        amount: Decimal = 20,
        currency: CurrencyCode = .eur
    ) -> Transaction {
        Transaction(
            accountID: UUID(),
            source: .manual,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -amount, currency: currency),
            bookedAt: date,
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
    }

    @Test("Weekly 20 €: 4 fällig im März, 1 bezahlt → due 80 / paid 20 / open 60")
    func weeklyPartialPaid() {
        let c = commitment(cadence: .weekly, amount: 20, nextExpected: date(2026, 3, 5))
        let period = monthInterval(year: 2026, month: 3)
        // Nur die Zahlung am 05.03. existiert.
        let transactions = [payment(on: date(2026, 3, 5))]

        let resolution = RecurringOccurrenceResolver().resolveOccurrences(
            commitment: c,
            explicitOccurrences: [],
            allTransactions: transactions,
            period: period,
            calendar: calendar
        )

        #expect(resolution.scheduled.count == 4) // 05./12./19./26.03.
        #expect(resolution.dueAmount == 80)
        #expect(resolution.paidAmount == 20)
        #expect(resolution.openAmount == 60)
        #expect(resolution.paidCount == 1)
        let paid = resolution.scheduled.filter(\.isPaid)
        #expect(paid.count == 1)
        #expect(paid.first?.scheduledDate == date(2026, 3, 5))
        // Key ist tag-normalisiert (§55), scheduledDate behält die Uhrzeit.
        #expect(paid.first?.id.scheduledDate == calendar.startOfDay(for: date(2026, 3, 5)))
    }

    @Test("Quarterly: genau ein Vorkommen im Quartal")
    func quarterlySingleOccurrence() {
        let c = commitment(name: "Versicherung", cadence: .quarterly, amount: 300, nextExpected: date(2026, 1, 15))
        let period = monthInterval(year: 2026, month: 1)

        let resolution = RecurringOccurrenceResolver().resolveOccurrences(
            commitment: c,
            explicitOccurrences: [],
            allTransactions: [],
            period: period,
            calendar: calendar
        )
        #expect(resolution.scheduled.count == 1)
        #expect(resolution.dueAmount == 300)
        #expect(resolution.openAmount == 300)
    }

    @Test("Monthly: genau ein Vorkommen im Monat")
    func monthlySingleOccurrence() {
        let c = commitment(cadence: .monthly, amount: 50, nextExpected: date(2026, 3, 15))
        let period = monthInterval(year: 2026, month: 3)

        let resolution = RecurringOccurrenceResolver().resolveOccurrences(
            commitment: c,
            explicitOccurrences: [],
            allTransactions: [],
            period: period,
            calendar: calendar
        )
        #expect(resolution.scheduled.count == 1)
        #expect(resolution.openAmount == 50)
    }

    @Test("Explizite Zuordnung gewinnt gegen die Heuristik (§57)")
    func explicitAssignmentWins() {
        let c = commitment(cadence: .monthly, amount: 20, nextExpected: date(2026, 3, 15))
        let period = monthInterval(year: 2026, month: 3)

        // Beide Transaktionen würden heuristisch matchen; die explizite
        // Zuordnung bestimmt, welche zählt.
        let heuristicTxn = payment(on: date(2026, 3, 15))
        let explicitTxn = payment(on: date(2026, 3, 10))
        let explicit = RecurringOccurrence(commitmentID: c.id, transactionID: explicitTxn.id)

        let resolution = RecurringOccurrenceResolver().resolveOccurrences(
            commitment: c,
            explicitOccurrences: [explicit],
            allTransactions: [heuristicTxn, explicitTxn],
            period: period,
            calendar: calendar
        )

        #expect(resolution.paidCount == 1)
        let paid = resolution.scheduled.first { $0.isPaid }
        #expect(paid?.matchOrigin == .explicitUserAssignment)
        #expect(paid?.matchedTransactionID == explicitTxn.id)
        // Die heuristic-Transaktion bezahlt KEIN Vorkommen (§56).
        #expect(!resolution.scheduled.contains { $0.matchedTransactionID == heuristicTxn.id })
    }

    @Test("Eine Transaktion kann nicht zwei Vorkommen bezahlen (§56)")
    func transactionPaysOnlyOneOccurrence() {
        let c = commitment(cadence: .weekly, amount: 20, nextExpected: date(2026, 3, 5))
        let period = monthInterval(year: 2026, month: 3)

        // Eine Zahlung am 08.03. liegt im Toleranzfenster BEIDER Vorkommen
        // (05.03. und 12.03.), sie bezahlt nur das nächste.
        let txn = payment(on: date(2026, 3, 8))

        let resolution = RecurringOccurrenceResolver().resolveOccurrences(
            commitment: c,
            explicitOccurrences: [],
            allTransactions: [txn],
            period: period,
            calendar: calendar
        )

        #expect(resolution.paidCount == 1)
        #expect(resolution.paidAmount == 20)
        #expect(resolution.openAmount == 60)
    }

    @Test("Zwei Transaktionen bezahlen zwei Vorkommen")
    func twoTransactionsPayTwoOccurrences() {
        let c = commitment(cadence: .weekly, amount: 20, nextExpected: date(2026, 3, 5))
        let period = monthInterval(year: 2026, month: 3)

        let resolution = RecurringOccurrenceResolver().resolveOccurrences(
            commitment: c,
            explicitOccurrences: [],
            allTransactions: [
                payment(on: date(2026, 3, 5)),
                payment(on: date(2026, 3, 12))
            ],
            period: period,
            calendar: calendar
        )

        #expect(resolution.paidCount == 2)
        #expect(resolution.paidAmount == 40)
        #expect(resolution.openAmount == 40)
    }

    @Test("Zukünftiges Vorkommen wird nicht von alter Transaktion bezahlt")
    func futureOccurrenceNotPaidByOldTransaction() {
        let c = commitment(cadence: .monthly, amount: 50, nextExpected: date(2026, 3, 15))
        let period = monthInterval(year: 2026, month: 3)

        // Alte Zahlung aus dem Vormonat und Zahlung außerhalb des
        // Toleranzfensters, keins der beiden bezahlt den 15.03.
        let resolution = RecurringOccurrenceResolver().resolveOccurrences(
            commitment: c,
            explicitOccurrences: [],
            allTransactions: [
                payment(on: date(2026, 2, 5), amount: 50),
                payment(on: date(2026, 2, 28), amount: 50)
            ],
            period: period,
            calendar: calendar
        )

        #expect(resolution.paidCount == 0)
        #expect(resolution.openAmount == 50)
    }

    @Test("Fremdwährung bleibt in der Resolution in Commitment-Währung (§61)")
    func foreignCurrencySeparated() {
        let c = commitment(
            name: "US-Abo",
            cadence: .monthly,
            amount: 10,
            currency: .usd,
            nextExpected: date(2026, 3, 15)
        )
        let period = monthInterval(year: 2026, month: 3)

        let resolution = RecurringOccurrenceResolver().resolveOccurrences(
            commitment: c,
            explicitOccurrences: [],
            allTransactions: [],
            period: period,
            calendar: calendar
        )
        #expect(resolution.dueAmount == 10)
        #expect(resolution.scheduled.allSatisfy { $0.currency == .usd })

        // Summary: USD fließt NICHT in die EUR-Basis-Summen.
        let summary = RecurringSummaryCalculator().summary(
            commitments: [c],
            latestOccurrences: [c.id: date(2026, 2, 15)],
            resolutions: [c.id: resolution],
            period: period,
            baseCurrency: .eur,
            calendar: calendar
        )
        #expect(summary.expenseDueInPeriod == 0)
        #expect(summary.foreignExpense.first?.dueInPeriod == 10)
        #expect(summary.foreignCurrencies.contains(.usd))
    }

    @Test("Summary mit Partial-Paid: wöchentlich 1 von 4 bezahlt → offen 60 (§52)")
    func summaryReflectsPartialPayment() {
        let c = commitment(cadence: .weekly, amount: 20, nextExpected: date(2026, 3, 5))
        let period = monthInterval(year: 2026, month: 3)
        let resolution = RecurringOccurrenceResolver().resolveOccurrences(
            commitment: c,
            explicitOccurrences: [],
            allTransactions: [payment(on: date(2026, 3, 5))],
            period: period,
            calendar: calendar
        )

        let summary = RecurringSummaryCalculator().summary(
            commitments: [c],
            latestOccurrences: [c.id: date(2026, 3, 5)],
            resolutions: [c.id: resolution],
            period: period,
            baseCurrency: .eur,
            calendar: calendar
        )
        #expect(summary.expenseDueInPeriod == 80)
        #expect(summary.openDueInPeriod == 60)
    }
}