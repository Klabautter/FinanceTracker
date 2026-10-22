import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@MainActor
@Suite("Pockets V1")
struct PocketsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test("Editor wandelt das inklusive Bis-Datum in eine exklusive Tagesgrenze um")
    func editorInclusiveDateBoundary() throws {
        let accountID = UUID()
        let input = PocketEditorInput(
            name: " Reise ",
            startDateInclusive: date(2026, 8, 10, hour: 15),
            endDateInclusive: date(2026, 8, 12, hour: 20),
            selectedAccountIDs: [accountID],
            calendar: calendar
        )

        let collection = try input.collection(
            replacing: nil,
            activeAccountIDs: [accountID],
            now: date(2026, 8, 1),
            calendar: calendar
        )

        #expect(collection.name == "Reise")
        #expect(collection.startDate == date(2026, 8, 10))
        #expect(collection.endDateExclusive == date(2026, 8, 13))
    }

    @Test("Editor blockiert leere Namen, inaktive Konten und umgekehrte Zeiträume")
    func editorValidation() {
        let activeID = UUID()
        let inactiveID = UUID()

        var input = PocketEditorInput(
            name: " ",
            startDateInclusive: date(2026, 8, 10),
            endDateInclusive: date(2026, 8, 12),
            selectedAccountIDs: [activeID],
            calendar: calendar
        )
        #expect(input.validationError(activeAccountIDs: [activeID], calendar: calendar) == .emptyName)

        input.name = "Reise"
        input.selectedAccountIDs = [inactiveID]
        #expect(input.validationError(activeAccountIDs: [activeID], calendar: calendar) == .noActiveAccount)

        input.selectedAccountIDs = [activeID]
        input.endDateInclusive = date(2026, 8, 9)
        #expect(input.validationError(activeAccountIDs: [activeID], calendar: calendar) == .invalidDateRange)
    }

    @Test("Status behandelt Start inklusiv und Ende exklusiv")
    func statusBoundaries() {
        let start = date(2026, 8, 10)
        let end = date(2026, 8, 13)

        #expect(PocketStatus.status(startDate: start, endDateExclusive: end, now: date(2026, 8, 9)) == .upcoming)
        #expect(PocketStatus.status(startDate: start, endDateExclusive: end, now: start) == .active)
        #expect(PocketStatus.status(startDate: start, endDateExclusive: end, now: end) == .completed)
    }

    @Test("Transaktionsauswahl filtert diakritikunabhängig und nach Konto")
    func candidateFilter() {
        let giroID = UUID()
        let cardID = UUID()
        let rows = [
            row(merchant: "Café Central", accountID: giroID, account: "Girokonto"),
            row(merchant: "BILLA", accountID: cardID, account: "Visa")
        ]

        #expect(PocketCandidateFilter.filter(rows, searchText: "cafe", accountID: nil).map(\.merchant) == ["Café Central"])
        #expect(PocketCandidateFilter.filter(rows, searchText: "", accountID: cardID).map(\.merchant) == ["BILLA"])
        #expect(PocketCandidateFilter.filter(rows, searchText: "billa", accountID: giroID).isEmpty)
    }

    @Test("Overrides schließen ein, fügen außerhalb des Scopes hinzu und stellen Automatik wieder her")
    func overrideLifecycle() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        let otherAccount = Account(name: "Visa", type: .creditCard, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account, otherAccount])

        let automatic = transaction(merchant: "Automatisch", accountID: account.id, day: 11)
        let outside = transaction(merchant: "Außerhalb", accountID: otherAccount.id, day: 11)
        try await dependencies.transactionRepository.upsert([automatic, outside])
        let collection = try TransactionCollection(
            name: "Test",
            systemIconName: "tag",
            startDate: date(2026, 8, 10),
            endDateExclusive: date(2026, 8, 13),
            accountIDs: [account.id]
        )
        try await dependencies.transactionCollectionRepository.upsert([collection])

        let model = PocketsModel(dependencies: dependencies)
        await model.load(now: date(2026, 8, 11))
        model.selectedCollectionID = collection.id
        #expect(model.selectedRows.map(\.id) == [automatic.id])

        await model.exclude(automatic)
        #expect(model.selectedRows.isEmpty)
        #expect(model.selectedExcludedRows.map(\.id) == [automatic.id])

        await model.restoreAutomation(for: automatic)
        #expect(model.selectedRows.map(\.id) == [automatic.id])
        #expect(model.selectedExcludedRows.isEmpty)

        await model.include(outside)
        #expect(model.selectedRows.contains { $0.id == outside.id && $0.isManuallyAdded })

        await model.restoreAutomation(for: outside)
        #expect(!model.selectedRows.contains { $0.id == outside.id })
        #expect(dependencies.changeTracker.revision == 4)
    }

    @Test("Summenanzeige erzeugt genau eine Zeile pro Währung")
    func summaryPresentationKeepsCurrenciesSeparate() {
        let summaries = [
            TransactionCollectionCurrencySummary(currency: .eur, spending: 40, income: 10),
            TransactionCollectionCurrencySummary(currency: .usd, spending: 8, income: 0)
        ]

        let rows = PocketCurrencySummaryPresentation.rows(from: summaries)
        #expect(rows.count == 2)
        #expect(rows.first { $0.currency == .eur }?.netCashflow == -30)
        #expect(rows.first { $0.currency == .usd }?.netCashflow == -8)
    }

    @Test("Mehrere Sammlungen werden gemeinsam geladen und Overrides bleiben isoliert")
    func batchSnapshotsKeepCollectionSemantics() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let giro = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        let card = Account(name: "Visa", type: .creditCard, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([giro, card])

        let giroAutomatic = transaction(merchant: "Giro automatisch", accountID: giro.id, day: 11)
        let cardAutomatic = transaction(merchant: "Card automatisch", accountID: card.id, day: 11)
        let manualInclude = transaction(merchant: "Manuell", accountID: card.id, day: 20)
        try await dependencies.transactionRepository.upsert([giroAutomatic, cardAutomatic, manualInclude])

        let giroCollection = try TransactionCollection(
            name: "Giro-Reise",
            systemIconName: "tag",
            startDate: date(2026, 8, 10),
            endDateExclusive: date(2026, 8, 13),
            accountIDs: [giro.id]
        )
        let cardCollection = try TransactionCollection(
            name: "Card-Reise",
            systemIconName: "tag",
            startDate: date(2026, 8, 10),
            endDateExclusive: date(2026, 8, 13),
            accountIDs: [card.id]
        )
        try await dependencies.transactionCollectionRepository.upsert([giroCollection, cardCollection])
        try await dependencies.transactionCollectionOverrideRepository.upsert([
            TransactionCollectionOverride(
                collectionID: giroCollection.id,
                transactionID: manualInclude.id,
                decision: .include
            ),
            TransactionCollectionOverride(
                collectionID: cardCollection.id,
                transactionID: cardAutomatic.id,
                decision: .exclude
            )
        ])

        let model = PocketsModel(dependencies: dependencies)
        await model.load(now: date(2026, 8, 11))

        let giroIDs = Set(try #require(model.items.first { $0.id == giroCollection.id }).snapshot.transactions.map(\.id))
        let cardIDs = Set(try #require(model.items.first { $0.id == cardCollection.id }).snapshot.transactions.map(\.id))
        #expect(giroIDs == [giroAutomatic.id, manualInclude.id])
        #expect(cardIDs.isEmpty)
    }

    @Test("Kandidaten nutzen paginierte Außenbereiche statt automatischen Collection-Scope")
    func candidatePagingSplitsOutsideScope() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let giro = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        let card = Account(name: "Visa", type: .creditCard, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([giro, card])

        let automatic = transaction(merchant: "Im Zeitraum", accountID: giro.id, day: 11)
        let before = transaction(merchant: "Vorher", accountID: giro.id, day: 8)
        let after = transaction(merchant: "Nachher", accountID: giro.id, day: 15)
        let otherAccount = transaction(merchant: "Anderes Konto", accountID: card.id, day: 11)
        try await dependencies.transactionRepository.upsert([automatic, before, after, otherAccount])
        let collection = try TransactionCollection(
            name: "Reise",
            systemIconName: "tag",
            startDate: date(2026, 8, 10),
            endDateExclusive: date(2026, 8, 13),
            accountIDs: [giro.id]
        )
        try await dependencies.transactionCollectionRepository.upsert([collection])

        let model = PocketsModel(dependencies: dependencies)
        await model.load(now: date(2026, 8, 11))
        model.selectedCollectionID = collection.id
        await model.loadCandidates()

        let candidateIDs = Set(model.candidateRows.map(\.id))
        #expect(!candidateIDs.contains(automatic.id))
        #expect(candidateIDs == [before.id, after.id, otherAccount.id])
    }

    @Test("100 Sammlungen laden 10.000 Transaktionen über den Batch-Pfad")
    func scaleOneHundredCollections() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Perf", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        var transactions: [Transaction] = []
        transactions.reserveCapacity(10_000)
        for index in 0..<10_000 {
            transactions.append(Transaction(
                accountID: account.id,
                source: .manual,
                kind: .purchase,
                amount: Money(amount: -1, currency: .eur),
                bookedAt: date(2026, 8, (index % 28) + 1),
                merchantDisplayName: "Perf \(index)"
            ))
        }
        try await dependencies.transactionRepository.upsert(transactions)

        let collections = try (0..<100).map { index in
            try TransactionCollection(
                name: "Sammlung \(index)",
                systemIconName: "tag",
                startDate: date(2026, 8, (index % 20) + 1),
                endDateExclusive: date(2026, 8, (index % 20) + 9),
                accountIDs: [account.id]
            )
        }
        try await dependencies.transactionCollectionRepository.upsert(collections)

        let model = PocketsModel(dependencies: dependencies)
        let start = ContinuousClock.now
        await model.load(now: date(2026, 8, 15))
        let duration = start.duration(to: .now)
        print("PERF Pockets: 100 Collections / 10k Transactions: \(duration)")

        #expect(model.items.count == 100)
        #expect(model.errorMessage == nil)
        // Debug-Gesamtläufe schwanken auf dem CI-/Entwicklungsrechner. Die
        // 10-s-Grenze fängt eine Rückkehr zum Collection-N+1-Pfad weiterhin
        // deutlich ab, ohne bei normaler Parallel-Last zu flaken.
        #expect(duration < .seconds(10), "Pocket-Batch-Laden dauerte \(duration)")
    }

    private func transaction(merchant: String, accountID: UUID, day: Int) -> Transaction {
        Transaction(
            accountID: accountID,
            source: .manual,
            kind: .purchase,
            amount: Money(amount: -10, currency: .eur),
            bookedAt: date(2026, 8, day),
            merchantDisplayName: merchant
        )
    }

    private func row(
        merchant: String,
        accountID: UUID,
        account: String
    ) -> PocketTransactionRow {
        PocketTransactionRow(
            transaction: Transaction(
                accountID: accountID,
                source: .manual,
                amount: Money(amount: -1, currency: .eur),
                bookedAt: date(2026, 8, 1),
                merchantDisplayName: merchant
            ),
            accountName: account,
            categoryName: "Ohne Kategorie",
            overrideDecision: nil
        )
    }
}
