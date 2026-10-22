import Foundation
import Testing

@testable import FinanceTracker

@Suite("SpendingIntelligence")
struct SpendingIntelligenceTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let accountID = UUID()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func expense(
        merchant: String,
        displayName: String,
        amount: Decimal,
        date: Date,
        accountID: UUID? = nil
    ) -> Transaction {
        Transaction(
            accountID: accountID ?? self.accountID,
            source: .openBanking,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -amount, currency: .eur),
            bookedAt: date,
            rawDescription: "\(merchant) Buchung",
            rawMerchantName: merchant,
            merchantDisplayName: displayName
        )
    }

    // MARK: - Recurring

    @Test("Monatliches Abo wird mit hoher Confidence erkannt")
    func detectsMonthlySubscription() {
        let detector = RecurringPaymentsDetector()
        let transactions = [
            expense(merchant: "SPOTIFY AB", displayName: "Spotify", amount: 10.99, date: date(2026, 5, 3)),
            expense(merchant: "SPOTIFY AB", displayName: "Spotify", amount: 10.99, date: date(2026, 6, 3)),
            expense(merchant: "SPOTIFY AB", displayName: "Spotify", amount: 10.99, date: date(2026, 7, 4)),
            expense(merchant: "SPOTIFY AB", displayName: "Spotify", amount: 10.99, date: date(2026, 8, 3))
        ]

        let series = detector.detect(transactions: transactions)

        #expect(series.count == 1)
        #expect(series.first?.cadence == .monthly)
        #expect(series.first?.medianAmount == Decimal(string: "10.99")!)
        #expect(series.first!.confidence >= 0.9)
        #expect(series.first!.nextExpectedDate > date(2026, 8, 3))
    }

    @Test("Unregelmäßige Händler werden nicht als wiederkehrend erkannt")
    func ignoresIrregularMerchants() {
        let detector = RecurringPaymentsDetector()
        let transactions = [
            expense(merchant: "REWE", displayName: "REWE", amount: 12.40, date: date(2026, 5, 2)),
            expense(merchant: "REWE", displayName: "REWE", amount: 87.15, date: date(2026, 5, 20)),
            expense(merchant: "REWE", displayName: "REWE", amount: 23.90, date: date(2026, 7, 11)),
            expense(merchant: "Amazon", displayName: "Amazon", amount: 44.44, date: date(2026, 6, 2))
        ]

        #expect(detector.detect(transactions: transactions).isEmpty)
    }

    @Test("Quartalsweise Zahlungen werden erkannt")
    func detectsQuarterly() {
        let detector = RecurringPaymentsDetector()
        let transactions = [
            expense(merchant: "Versicherung AG", displayName: "Versicherung AG", amount: 240, date: date(2025, 9, 1)),
            expense(merchant: "Versicherung AG", displayName: "Versicherung AG", amount: 240, date: date(2025, 12, 1)),
            expense(merchant: "Versicherung AG", displayName: "Versicherung AG", amount: 240, date: date(2026, 3, 2)),
            expense(merchant: "Versicherung AG", displayName: "Versicherung AG", amount: 240, date: date(2026, 6, 1))
        ]

        let series = detector.detect(transactions: transactions)

        #expect(series.count == 1)
        #expect(series.first?.cadence == .quarterly)
    }

    @Test("Serien trennen Konten und Währungen und bewahren die Händleridentität")
    func recurringSeriesIdentity() {
        let otherAccount = UUID()
        let merchantID = UUID()
        let history = [accountID, otherAccount].flatMap { account in
            [CurrencyCode.eur, .usd].flatMap { currency in
                [6, 7, 8].map { month in
                    var transaction = expense(merchant: "Spotify", displayName: "Spotify",
                                              amount: 11, date: date(2026, month, 3), accountID: account)
                    transaction.merchantID = merchantID
                    transaction.amount = Money(amount: -11, currency: currency)
                    return transaction
                }
            }
        }
        let series = RecurringPaymentsDetector().detect(transactions: history, calendar: calendar,
                                                         now: date(2026, 8, 4))
        #expect(series.count == 4)
        #expect(Set(series.map(\.id)).count == 4)
        #expect(series.allSatisfy { $0.merchantKey == merchantID.uuidString })
        for item in series {
            let commitment = RecurringCommitment(name: item.displayName, merchantKey: RecurringMerchantIdentity(accountID: item.accountID, merchantKey: item.merchantKey).persistedKey,
                expectedAmount: item.medianAmount, currency: item.currency)
            #expect(RecurringPaymentMatcher.matchingTransactions(for: commitment, in: history).count == 3)
        }
    }

    // MARK: - Transfers

    @Test("Interner Transfer zwischen eigenen Konten wird gefunden")
    func detectsInternalTransfer() {
        let detector = TransferDetector()
        let giro = UUID()
        let savings = UUID()

        let out = Transaction(
            accountID: giro,
            source: .openBanking,
            kind: .unknown,
            amount: Money(amount: -1000, currency: .eur),
            bookedAt: date(2026, 8, 5),
            rawDescription: "Umbuchung"
        )
        let inn = Transaction(
            accountID: savings,
            source: .openBanking,
            kind: .unknown,
            amount: Money(amount: 1000, currency: .eur),
            bookedAt: date(2026, 8, 6),
            rawDescription: "Eingang"
        )

        let candidates = detector.detect(
            transactions: [out, inn],
            baseCurrency: .eur,
            calendar: calendar
        )

        #expect(candidates.count == 1)
        #expect(candidates[0].daysApart == 1)
        #expect(candidates[0].amount == 1000)
    }

    @Test("Gehalt wird nicht als Transfer-Gegenstück gematcht")
    func salaryNotMatched() {
        let detector = TransferDetector()

        let out = Transaction(
            accountID: UUID(),
            source: .openBanking,
            amount: Money(amount: -100, currency: .eur),
            bookedAt: date(2026, 8, 5)
        )
        let salary = Transaction(
            accountID: UUID(),
            source: .openBanking,
            amount: Money(amount: 2850, currency: .eur),
            bookedAt: date(2026, 8, 30)
        )

        #expect(detector.detect(transactions: [out, salary], baseCurrency: .eur, calendar: calendar).isEmpty)
    }

    // MARK: - Review Queue

    @Test("Review-Queue sammelt unkategorisierte, Fremdwährung und Transfer-Kandidaten")
    func reviewQueueFlags() {
        let builder = ReviewQueueBuilder()
        let otherAccount = UUID()

        let uncategorized = expense(merchant: "Kiosk", displayName: "Kiosk", amount: 3.50, date: date(2026, 8, 1))

        var foreign = expense(merchant: "US Shop", displayName: "US Shop", amount: 25, date: date(2026, 8, 2))
        foreign.amount = Money(amount: -25, currency: .usd)
        foreign.categoryID = UUID()

        var knownCategorized = expense(merchant: "REWE", displayName: "REWE", amount: 40, date: date(2026, 8, 3))
        knownCategorized.categoryID = UUID()

        let transferOut = expense(merchant: "Umbuchung", displayName: "Umbuchung", amount: 500, date: date(2026, 8, 4), accountID: accountID)

        let transferIn = Transaction(
            accountID: otherAccount,
            source: .openBanking,
            amount: Money(amount: 500, currency: .eur),
            bookedAt: date(2026, 8, 5)
        )

        let items = builder.buildItems(transactions: [
            uncategorized, foreign, knownCategorized, transferOut, transferIn
        ], baseCurrency: .eur, calendar: calendar)

        let reasonsForUncategorized = items.filter { $0.transaction.id == uncategorized.id }.map(\.reason)
        #expect(reasonsForUncategorized.contains(.uncategorized))

        #expect(items.contains { $0.transaction.id == foreign.id && $0.reason == .foreignCurrency })

        #expect(items.contains { $0.reason == .possibleTransfer && $0.transaction.id == transferOut.id })
        #expect(items.contains { $0.reason == .possibleTransfer && $0.transaction.id == transferIn.id })

        #expect(!items.contains { $0.transaction.id == knownCategorized.id && $0.reason == .uncategorized })
    }

    @Test("Bereits geprüfte Transferkandidaten erscheinen nicht erneut")
    func reviewedTransferCandidateIsHidden() {
        let builder = ReviewQueueBuilder()
        var debit = expense(merchant: "Umbuchung", displayName: "Umbuchung", amount: 100, date: date(2026, 8, 4))
        var credit = Transaction(
            accountID: UUID(),
            source: .openBanking,
            amount: Money(amount: 100, currency: .eur),
            bookedAt: date(2026, 8, 5)
        )
        debit.reviewed = true
        credit.reviewed = true

        let items = builder.buildItems(transactions: [debit, credit], baseCurrency: .eur, calendar: calendar)

        #expect(!items.contains { $0.reason == .possibleTransfer })
    }
}

@Suite("TransferDetectorIndex")
struct TransferDetectorIndexTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func transaction(
        id: UUID = UUID(),
        accountID: UUID,
        amount: Decimal,
        currency: CurrencyCode = .eur,
        day: Int,
        hour: Int = 12,
        status: TransactionStatus = .booked
    ) -> Transaction {
        Transaction(
            id: id,
            accountID: accountID,
            source: .openBanking,
            status: status,
            amount: Money(amount: amount, currency: currency),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour))!
        )
    }

    @Test("Gleichstände sind unabhängig von der Eingabereihenfolge stabil")
    func stableTieBreak() throws {
        let debitAccount = UUID()
        let creditAccount = UUID()
        let debitID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000100"))
        let firstCreditID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondCreditID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let debit = transaction(id: debitID, accountID: debitAccount, amount: -100, day: 10)
        let firstCredit = transaction(id: firstCreditID, accountID: creditAccount, amount: 100, day: 11)
        let secondCredit = transaction(id: secondCreditID, accountID: creditAccount, amount: 100, day: 11)
        let detector = TransferDetector()

        let forward = detector.detect(
            transactions: [debit, secondCredit, firstCredit],
            baseCurrency: .eur,
            calendar: calendar
        )
        let reversed = detector.detect(
            transactions: [firstCredit, debit, secondCredit],
            baseCurrency: .eur,
            calendar: calendar
        )

        #expect(forward == reversed)
        #expect(forward.first?.creditTransactionID == firstCreditID)
    }

    @Test("Debit-Reihenfolge und Eins-zu-eins-Verbrauch bleiben erhalten")
    func debitOrderAndOneToOneConsumption() {
        let debitAccount = UUID()
        let creditAccount = UUID()
        let earlyDebit = transaction(accountID: debitAccount, amount: -250, day: 9)
        let lateDebit = transaction(accountID: debitAccount, amount: -250, day: 10)
        let credit = transaction(accountID: creditAccount, amount: 250, day: 11)

        let result = TransferDetector().detect(
            transactions: [credit, lateDebit, earlyDebit],
            baseCurrency: .eur,
            calendar: calendar
        )

        #expect(result.count == 1)
        #expect(result.first?.debitTransactionID == earlyDebit.id)
        #expect(result.first?.creditTransactionID == credit.id)
        #expect(result.first?.daysApart == 2)
    }

    @Test("Toleranz, Währung, Konto und Zeitfenster bleiben strikt")
    func indexedEligibilityBoundaries() {
        let debitAccount = UUID()
        let otherAccount = UUID()
        let detector = TransferDetector(maxDaysApart: 4, amountTolerance: Decimal(string: "0.01")!)
        let debit = transaction(accountID: debitAccount, amount: -100, day: 10)
        let sameAccount = transaction(accountID: debitAccount, amount: Decimal(string: "100.00")!, day: 10)
        let wrongCurrency = transaction(accountID: otherAccount, amount: Decimal(string: "100.00")!, currency: .usd, day: 10)
        let tooLate = transaction(accountID: otherAccount, amount: Decimal(string: "100.00")!, day: 15)
        let outsideTolerance = transaction(accountID: otherAccount, amount: Decimal(string: "100.011")!, day: 10)
        let boundary = transaction(accountID: otherAccount, amount: Decimal(string: "100.01")!, day: 14)

        let result = detector.detect(
            transactions: [debit, sameAccount, wrongCurrency, tooLate, outsideTolerance, boundary],
            baseCurrency: .eur,
            calendar: calendar
        )

        #expect(result.count == 1)
        #expect(result.first?.creditTransactionID == boundary.id)
        #expect(result.first?.daysApart == 4)
    }

    @Test("Stornierte Zustände sind ausgeschlossen, pending und booked zulässig")
    func statusSemantics() {
        let debitAccount = UUID()
        let creditAccount = UUID()
        let pendingDebit = transaction(accountID: debitAccount, amount: -80, day: 10, status: .pending)
        let bookedCredit = transaction(accountID: creditAccount, amount: 80, day: 10, status: .booked)
        let bookedDebit = transaction(accountID: debitAccount, amount: -90, day: 10, status: .booked)
        let cancelledCredit = transaction(accountID: creditAccount, amount: 90, day: 10, status: .cancelled)
        let reversedDebit = transaction(accountID: debitAccount, amount: -70, day: 10, status: .reversed)
        let pendingCreditDebit = transaction(accountID: debitAccount, amount: -70, day: 10, status: .booked)
        let pendingCredit = transaction(accountID: creditAccount, amount: 70, day: 10, status: .pending)

        let result = TransferDetector().detect(
            transactions: [
                pendingDebit, bookedCredit, bookedDebit, cancelledCredit,
                reversedDebit, pendingCreditDebit, pendingCredit
            ],
            baseCurrency: .eur,
            calendar: calendar
        )

        #expect(result.count == 2)
        #expect(result.contains {
            $0.debitTransactionID == pendingDebit.id && $0.creditTransactionID == bookedCredit.id
        })
        #expect(result.contains {
            $0.debitTransactionID == pendingCreditDebit.id && $0.creditTransactionID == pendingCredit.id
        })
    }

    @Test("Der Abstand folgt lokalen Kalendertagen")
    func calendarDaySemantics() {
        let debit = transaction(accountID: UUID(), amount: -42, day: 10, hour: 23)
        let credit = transaction(accountID: UUID(), amount: 42, day: 11, hour: 0)

        let result = TransferDetector().detect(
            transactions: [debit, credit],
            baseCurrency: .eur,
            calendar: calendar
        )

        #expect(result.first?.daysApart == 1)
    }

    @Test("12.000 kollidierende Transferpaare bleiben im indexierten Pfad")
    func scaleTwelveThousandCollidingPairs() {
        let pairCount = 12_000
        let debitAccount = UUID()
        let creditAccount = UUID()
        var transactions: [Transaction] = []
        transactions.reserveCapacity(pairCount * 2)

        for _ in 0..<pairCount {
            transactions.append(transaction(accountID: debitAccount, amount: -100, day: 10))
            transactions.append(transaction(accountID: creditAccount, amount: 100, day: 10))
        }

        let start = ContinuousClock.now
        let result = TransferDetector().detect(
            transactions: transactions,
            baseCurrency: .eur,
            calendar: calendar
        )
        let duration = start.duration(to: .now)

        #expect(result.count == pairCount)
        #expect(duration < .seconds(10), "Transfer-Erkennung für 12k Paare dauerte \(duration)")
    }
}

@Suite("RecurringMultiCurrency")
struct RecurringMultiCurrencyTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let accountID = UUID()

    private func expense(merchant: String, displayName: String, amount: Decimal, date: Date, currency: CurrencyCode = .eur) -> Transaction {
        Transaction(
            accountID: accountID,
            source: .openBanking,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -amount, currency: currency),
            bookedAt: date,
            rawDescription: merchant + " Buchung",
            rawMerchantName: merchant,
            merchantDisplayName: displayName
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("Gleicher Merchant in verschiedenen Währungen erzeugt getrennte Serien")
    func recurringSplitByCurrency() {
        let detector = RecurringPaymentsDetector()
        var usdTxns: [Transaction] = []
        for (index, month) in [5, 6, 7, 8].enumerated() {
            var txn = expense(merchant: "SPOTIFY AB", displayName: "Spotify", amount: 12.99, date: date(2026, month, 3))
            txn.amount = Money(amount: -Decimal(string: "12.99")!, currency: .usd)
            _ = index
            usdTxns.append(txn)
        }

        let eurTxns = [
            expense(merchant: "SPOTIFY AB", displayName: "Spotify", amount: 10.99, date: date(2026, 5, 3)),
            expense(merchant: "SPOTIFY AB", displayName: "Spotify", amount: 10.99, date: date(2026, 6, 3)),
            expense(merchant: "SPOTIFY AB", displayName: "Spotify", amount: 10.99, date: date(2026, 7, 4))
        ]

        let series = detector.detect(transactions: eurTxns + usdTxns)

        #expect(series.count == 2)
        #expect(Set(series.map { $0.currency }).count == 2)
        #expect(Set(series.map { $0.id }).count == 2)
    }

    @Test("Decimal-Median behält Präzision ohne Double-Umweg")
    func decimalMedianPrecision() {
        let detector = RecurringPaymentsDetector()
        let transactions = [
            expense(merchant: "FIXKOSTEN X", displayName: "Fixkosten X", amount: Decimal(string: "19.995")!, date: date(2026, 5, 1)),
            expense(merchant: "FIXKOSTEN X", displayName: "Fixkosten X", amount: Decimal(string: "19.985")!, date: date(2026, 6, 1)),
            expense(merchant: "FIXKOSTEN X", displayName: "Fixkosten X", amount: Decimal(string: "19.990")!, date: date(2026, 7, 1))
        ]

        let series = detector.detect(transactions: transactions)
        #expect(series.count == 1)
        #expect(series[0].medianAmount == Decimal(string: "19.990")!)
    }

}
