import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@MainActor
@Suite("RecurringOccurrenceResolver")
struct RecurringOccurrenceResolverTests {

    private let resolver = RecurringOccurrenceResolver()
    private let calendar = Calendar(identifier: .gregorian)

    private func period(start: Date, days: Int) -> DateInterval {
        DateInterval(start: start, end: calendar.date(byAdding: .day, value: days, to: start)!)
    }

    private func txn(
        merchant: String,
        amount: Decimal,
        date: Date,
        currency: CurrencyCode = .eur
    ) -> Transaction {
        Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .demo,
            externalID: UUID().uuidString,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: amount, currency: currency),
            bookedAt: date,
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
    }

    private func commitment(
        name: String,
        merchantKey: String?,
        amount: Decimal = Decimal(string: "10.99")!
    ) -> RecurringCommitment {
        RecurringCommitment(
            name: name,
            merchantKey: merchantKey,
            direction: .expense,
            cadence: .monthly,
            amountPolicy: .fixed,
            expectedAmount: amount,
            currency: .eur
        )
    }

    private func makeOccurrences(
        _ occurrences: [(RecurringOccurrence, Transaction)]
    ) -> ([RecurringOccurrence], [Transaction]) {
        (occurrences.map(\.0), occurrences.map(\.1))
    }

    @Test("Manuelle Occurrence gewinnt gegen Heuristik")
    func manualOccurrenceWins() {
        let now = calendar.startOfDay(for: Date())
        let period = period(start: now, days: 30)

        let commitment = commitment(name: "Spotify", merchantKey: "SPOTIFY")
        // Heuristik würde diese nicht matchen (anderer Betrag), die explizite
        // Zuordnung zählt trotzdem.
        let explicit = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "12.99")!, date: now)
        let occurrence = RecurringOccurrence(commitmentID: commitment.id, transactionID: explicit.id)
        let background = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "10.99")!, date: now)

        let result = resolver.resolve(
            commitment: commitment,
            explicitOccurrences: [occurrence],
            allTransactions: [explicit, background],
            period: period,
            calendar: calendar
        )

        #expect(result.isExplicitlyAssigned)
        #expect(result.matchedTransactions.map(\.id) == [explicit.id])
        #expect(result.latestOccurrence == explicit.displayDate)
    }

    @Test("Manuelle Occurrence überlebt Umbenennung")
    func manualOccurrenceSurvivesRename() {
        let now = calendar.startOfDay(for: Date())
        let period = period(start: now, days: 30)

        var commitment = commitment(name: "Spotify", merchantKey: "SPOTIFY")
        let explicit = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "12.99")!, date: now)
        let occurrence = RecurringOccurrence(commitmentID: commitment.id, transactionID: explicit.id)

        commitment.name = "Musik-Abo" // Display-Name ändert sich, Identity bleibt

        let result = resolver.resolve(
            commitment: commitment,
            explicitOccurrences: [occurrence],
            allTransactions: [explicit],
            period: period,
            calendar: calendar
        )
        #expect(result.isExplicitlyAssigned)
        #expect(result.matchedTransactions.count == 1)
    }

    @Test("Merchant-Mismatch zählt trotzdem (User choice wins)")
    func merchantMismatchStillCounts() {
        let now = calendar.startOfDay(for: Date())
        let period = period(start: now, days: 30)

        let commitment = commitment(name: "Spotify", merchantKey: "SPOTIFY")
        // Weder Merchant (DEEZER) noch Betrag (99) passen zur Signatur
        // die explizite Zuordnung des Nutzers ist dennoch authoritative.
        let explicit = txn(merchant: "DEEZER FAMILY", amount: -Decimal(string: "99.00")!, date: now)
        let occurrence = RecurringOccurrence(commitmentID: commitment.id, transactionID: explicit.id)

        let result = resolver.resolve(
            commitment: commitment,
            explicitOccurrences: [occurrence],
            allTransactions: [explicit],
            period: period,
            calendar: calendar
        )
        #expect(result.isExplicitlyAssigned)
        #expect(result.matchedTransactions.count == 1)
    }

    @Test("Ohne explizite Zuordnung: heuristischer Fallback bei merchantKey")
    func heuristicFallbackWithoutExplicit() {
        let now = calendar.startOfDay(for: Date())
        let period = period(start: now, days: 30)

        let commitment = commitment(name: "Spotify", merchantKey: "SPOTIFY")
        let heuristicMatch = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "10.99")!, date: now)

        let result = resolver.resolve(
            commitment: commitment,
            explicitOccurrences: [],
            allTransactions: [heuristicMatch],
            period: period,
            calendar: calendar
        )
        #expect(!result.isExplicitlyAssigned)
        #expect(result.matchedTransactions.count == 1)
    }

    @Test("Entfernen der Zuordnung: Fallback auf Heuristik oder offen")
    func removalFallsBack() {
        let now = calendar.startOfDay(for: Date())
        let period = period(start: now, days: 30)

        // Fall 1: merchantKey vorhanden → Heuristik greift wieder.
        let keyed = commitment(name: "Spotify", merchantKey: "SPOTIFY")
        let match = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "10.99")!, date: now)
        let afterRemoval = resolver.resolve(
            commitment: keyed,
            explicitOccurrences: [],
            allTransactions: [match],
            period: period,
            calendar: calendar
        )
        #expect(!afterRemoval.isExplicitlyAssigned)
        #expect(afterRemoval.matchedTransactions.count == 1)

        // Fall 2: ohne merchantKey → keine Heuristik → offen.
        let manual = commitment(name: "Manuelles Abo", merchantKey: nil)
        let unassignable = resolver.resolve(
            commitment: manual,
            explicitOccurrences: [],
            allTransactions: [match],
            period: period,
            calendar: calendar
        )
        #expect(!unassignable.isExplicitlyAssigned)
        #expect(unassignable.matchedTransactions.isEmpty)
    }

    @Test("Occurrence außerhalb der Periode zählt nicht als bezahlt im Zeitraum")
    func occurrenceOutsidePeriodNotPaid() {
        let now = calendar.startOfDay(for: Date())
        let period = period(start: now, days: 7)

        let commitment = commitment(name: "Spotify", merchantKey: "SPOTIFY")
        let old = txn(
            merchant: "SPOTIFY AB",
            amount: -Decimal(string: "10.99")!,
            date: calendar.date(byAdding: .day, value: -60, to: now)!
        )
        let occurrence = RecurringOccurrence(commitmentID: commitment.id, transactionID: old.id)

        let result = resolver.resolve(
            commitment: commitment,
            explicitOccurrences: [occurrence],
            allTransactions: [old],
            period: period,
            calendar: calendar
        )
        // Kein expliziter Match im Zeitraum, Heuristik findet in der Periode
        // nichts → offen (matched leer), latestOccurrence bleibt aber sichtbar.
        #expect(result.matchedTransactions.isEmpty)
        #expect(result.latestOccurrence == old.displayDate)
    }

    @Test("Persistenz: Occurrence anlegen und entfernen")
    func occurrencePersistence() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        let commitment = commitment(name: "Spotify", merchantKey: "SPOTIFY")
        try await dependencies.recurringCommitmentRepository.upsert([commitment])

        let transaction = txn(
            merchant: "SPOTIFY AB",
            amount: -Decimal(string: "12.99")!,
            date: Date()
        )
        try await dependencies.transactionRepository.upsert([transaction])

        let occurrence = RecurringOccurrence(commitmentID: commitment.id, transactionID: transaction.id)
        try await dependencies.recurringCommitmentRepository.addOccurrence(occurrence)

        #expect(try await dependencies.recurringCommitmentRepository.allOccurrences().count == 1)
        #expect(try await dependencies.recurringCommitmentRepository.occurrences(commitmentID: commitment.id).count == 1)

        try await dependencies.recurringCommitmentRepository.removeOccurrence(id: occurrence.id)
        #expect(try await dependencies.recurringCommitmentRepository.allOccurrences().isEmpty)
        #expect(try await dependencies.transactionRepository.count() == 1) // Transaktion bleibt
    }

    @Test("FixkostenModel: manuelle Zuordnung bestimmt den Paid-Status im Haupt-Screen")
    func modelHonorsExplicitOccurrence() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        // Commitment OHNE merchantKey: Heuristik kann nie matchen
        // nur die manuelle Zuordnung macht es bezahlt.
        let manual = commitment(name: "Vereinsbeitrag", merchantKey: nil)
        try await dependencies.recurringCommitmentRepository.upsert([manual])

        let transaction = txn(
            merchant: "SPORTVEREIN BEITRAG",
            amount: -Decimal(string: "25.00")!,
            date: Date()
        )
        try await dependencies.transactionRepository.upsert([transaction])

        let model = FixkostenModel(dependencies: dependencies)
        await model.load()
        #expect(model.paidTransactionCounts[manual.id] == 0) // noch offen

        try await dependencies.recurringCommitmentRepository.addOccurrence(
            RecurringOccurrence(commitmentID: manual.id, transactionID: transaction.id)
        )
        await model.load()
        #expect(model.paidTransactionCounts[manual.id] == 1)
        #expect(model.explicitOccurrenceCounts[manual.id] == 1)
        #expect(model.latestOccurrenceDates[manual.id] != nil)
        #expect(model.openTotal == 0) // nothing open anymore
    }

    // MARK: - Offene Vorkommen inkl. überfälliger Termine

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test("Gestern fälliger, unbezahlter Termin bleibt als überfällig sichtbar")
    func overdueOccurrenceStaysVisible() {
        var plan = commitment(name: "Miete", merchantKey: "VERMIETER", amount: 900)
        plan.nextExpectedDate = day(2026, 10, 12)
        let now = day(2026, 10, 13, hour: 9)

        let open = resolver.openOccurrences(
            commitment: plan,
            explicitOccurrences: [],
            allTransactions: [],
            now: now,
            end: day(2026, 11, 20),
            calendar: calendar
        )

        #expect(open.map(\.scheduledDate) == [day(2026, 10, 12), day(2026, 11, 12)])
        #expect(open[0].isOverdue(now: now, calendar: calendar))
        #expect(!open[1].isOverdue(now: now, calendar: calendar))
    }

    @Test("Bezahlter Termin und Termine jenseits der Karenz erscheinen nicht als überfällig")
    func paidOrOldOccurrencesAreNotOverdue() {
        var plan = commitment(name: "Miete", merchantKey: "VERMIETER", amount: 900)
        plan.nextExpectedDate = day(2026, 10, 12)
        let payment = txn(merchant: "VERMIETER", amount: -900, date: day(2026, 10, 10))

        let paid = resolver.openOccurrences(
            commitment: plan,
            explicitOccurrences: [],
            allTransactions: [payment],
            now: day(2026, 10, 13, hour: 9),
            end: day(2026, 10, 30),
            calendar: calendar
        )
        #expect(paid.isEmpty)

        let afterGrace = resolver.openOccurrences(
            commitment: plan,
            explicitOccurrences: [],
            allTransactions: [],
            now: day(2026, 10, 25),
            end: day(2026, 11, 5),
            calendar: calendar
        )
        #expect(afterGrace.isEmpty)
    }
}
