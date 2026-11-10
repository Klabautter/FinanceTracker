import Foundation
import Testing

@testable import FinanceTracker

/// Vorgemerkte Bankumsätze (AGENTS #21: Reconciliation, nicht bloß
/// Deduplizierung). Eine Vormerkung, die die Bank später mit anderem Betrag
/// bucht oder nie bucht, darf weder ewig vorgemerkt bleiben noch doppelt
/// zählen.
@MainActor
@Suite("PendingReconciliation")
struct PendingReconciliationTests {
    private struct Setup {
        let dependencies: AppDependencies
        let provider: MockBankDataProvider
        let service: BankSyncService
        let connectionID: UUID
    }

    private func makeSetup() async throws -> Setup {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let provider = MockBankDataProvider()
        let service = BankSyncService(dependencies: dependencies, provider: provider)
        let connection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "pending-1",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )
        return Setup(dependencies: dependencies, provider: provider, service: service, connectionID: connection.id)
    }

    /// Abruf mit dem gespeicherten Stand der Verbindung: Ab dem zweiten Abruf
    /// fragt er nur noch „seit dem letzten Abruf minus sieben Tage" ab.
    @discardableResult
    private func sync(_ setup: Setup, _ transactions: [RemoteBankTransaction]) async throws -> BankSyncResult {
        setup.provider.stubbedTransactions = transactions
        let connection = try #require(
            try await setup.dependencies.connectionRepository.connections().first { $0.id == setup.connectionID }
        )
        return try await setup.service.sync(connection: connection)
    }

    private func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: Date()))!
    }

    private func remote(
        _ id: String?,
        _ amount: String,
        daysAgo days: Int,
        pending: Bool,
        merchant: String = "TANKSTELLE NORD"
    ) -> RemoteBankTransaction {
        RemoteBankTransaction(
            externalID: id,
            state: pending ? .pending : .booked,
            amount: Money(amount: Decimal(string: amount)!, currency: .eur),
            bookingDate: pending ? nil : daysAgo(days),
            valueDate: daysAgo(days),
            creditorName: merchant,
            debtorName: nil,
            remittanceInformation: "\(merchant) Kartenzahlung"
        )
    }

    private func stored(_ setup: Setup) async throws -> [Transaction] {
        try await setup.dependencies.transactionRepository.transactions(matching: TransactionQuery())
    }

    /// Was in Kontostand und Auswertungen zählt.
    private func countedTotal(_ transactions: [Transaction]) -> Decimal {
        transactions
            .filter { $0.status != .cancelled && $0.status != .reversed }
            .reduce(Decimal(0)) { $0 + $1.amount.amount }
    }

    @Test("Gleiche Bank-Kennung, gebucht mit anderem Betrag: dieselbe Zeile wird gebucht und übernimmt den Betrag")
    func bookedWithSameIDTakesBookedAmount() async throws {
        let setup = try await makeSetup()
        try await sync(setup, [remote("AUTH-1", "-50.00", daysAgo: 3, pending: true)])
        let pendingRow = try #require(try await stored(setup).first)
        // Der Nutzer hat die Vormerkung schon eingeordnet.
        let categoryID = UUID()
        var categorized = pendingRow
        categorized.categoryID = categoryID
        try await setup.dependencies.transactionRepository.upsert([categorized])

        let result = try await sync(setup, [remote("AUTH-1", "-52.30", daysAgo: 1, pending: false)])

        let rows = try await stored(setup)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.id == pendingRow.id)
        #expect(row.status == .booked)
        #expect(row.amount == Money(amount: Decimal(string: "-52.30")!, currency: .eur))
        #expect(row.bookedAt == daysAgo(1))
        #expect(row.categoryID == categoryID)
        #expect(result.updatedCount == 1)
        #expect(result.importedCount == 0)
    }

    @Test("Ohne gemeinsame Kennung mit anderem Betrag gebucht: Vormerkung storniert, nichts zählt doppelt")
    func bookedWithOtherAmountDoesNotDoubleCount() async throws {
        let setup = try await makeSetup()
        try await sync(setup, [remote(nil, "-50.00", daysAgo: 3, pending: true)])

        try await sync(setup, [remote("BOOK-7", "-52.30", daysAgo: 1, pending: false)])

        let rows = try await stored(setup)
        #expect(rows.count == 2)
        #expect(rows.first { $0.amount.amount == -50 }?.status == .cancelled)
        #expect(rows.first { $0.externalID == "BOOK-7" }?.status == .booked)
        #expect(countedTotal(rows) == Decimal(string: "-52.30")!)
    }

    @Test("Nie gebucht: Vormerkung, die die Bank nicht mehr meldet, wird storniert und bleibt nachvollziehbar")
    func droppedPendingIsCancelled() async throws {
        let setup = try await makeSetup()
        try await sync(setup, [
            remote("AUTH-2", "-80.00", daysAgo: 2, pending: true, merchant: "HOTEL KAUTION"),
            remote("BOOK-1", "-12.00", daysAgo: 2, pending: false, merchant: "BAECKEREI")
        ])

        let result = try await sync(setup, [remote("BOOK-1", "-12.00", daysAgo: 2, pending: false, merchant: "BAECKEREI")])

        let rows = try await stored(setup)
        #expect(rows.count == 2)
        let hold = try #require(rows.first { $0.externalID == "AUTH-2" })
        #expect(hold.status == .cancelled)
        #expect(hold.amount.amount == -80)
        #expect(countedTotal(rows) == -12)
        #expect(result.updatedCount == 1)

        // Der Abruf steht im Importverlauf, mit dem Zustand davor (Undo).
        let batches = try await setup.dependencies.importBatchRepository.batches()
        let mutation = try #require(batches.flatMap(\.mutations).first {
            $0.transactionID == hold.id && $0.kind == .updated
        })
        #expect(mutation.previousSnapshot?.statusRaw == TransactionStatus.pending.rawValue)
    }

    @Test("Weiter gemeldete Vormerkung bleibt vorgemerkt")
    func stillReportedPendingStays() async throws {
        let setup = try await makeSetup()
        let pending = remote("AUTH-3", "-30.00", daysAgo: 1, pending: true)
        try await sync(setup, [pending])

        let result = try await sync(setup, [pending])

        let rows = try await stored(setup)
        #expect(rows.map(\.status) == [.pending])
        #expect(result.updatedCount == 0)
    }

    @Test("Vormerkung vor dem abgerufenen Zeitraum bleibt unangetastet")
    func pendingOutsideFetchedWindowStays() async throws {
        let setup = try await makeSetup()
        try await sync(setup, [remote(nil, "-40.00", daysAgo: 20, pending: true)])

        // Zweiter Abruf fragt nur die letzten sieben Tage ab: Über eine
        // 20 Tage alte Vormerkung sagt die Antwort nichts aus.
        try await sync(setup, [remote("BOOK-2", "-5.00", daysAgo: 1, pending: false, merchant: "KIOSK")])

        let rows = try await stored(setup)
        #expect(rows.first { $0.amount.amount == -40 }?.status == .pending)
    }

    @Test("Storniert und doch gebucht: dieselbe Zeile wird gebucht, Kategorie bleibt")
    func cancelledPendingIsRevivedByBooking() async throws {
        let setup = try await makeSetup()
        try await sync(setup, [remote(nil, "-25.00", daysAgo: 3, pending: true)])
        let pendingRow = try #require(try await stored(setup).first)
        let categoryID = UUID()
        var categorized = pendingRow
        categorized.categoryID = categoryID
        try await setup.dependencies.transactionRepository.upsert([categorized])
        // Die Bank lässt die Vormerkung einen Abruf lang aus.
        try await sync(setup, [])
        #expect(try await stored(setup).first?.status == .cancelled)

        try await sync(setup, [remote("BOOK-3", "-25.00", daysAgo: 1, pending: false)])

        let rows = try await stored(setup)
        #expect(rows.count == 1)
        #expect(rows.first?.id == pendingRow.id)
        #expect(rows.first?.status == .booked)
        #expect(rows.first?.categoryID == categoryID)
    }

    @Test("Storniert und wieder als Vormerkung gemeldet: wieder vorgemerkt")
    func cancelledPendingReportedAgainIsPendingAgain() async throws {
        let setup = try await makeSetup()
        let pending = remote("AUTH-4", "-60.00", daysAgo: 2, pending: true)
        try await sync(setup, [pending])
        try await sync(setup, [])
        #expect(try await stored(setup).first?.status == .cancelled)

        try await sync(setup, [pending])

        let rows = try await stored(setup)
        #expect(rows.map(\.status) == [.pending])
    }

    @Test("Ohne Angabe zum Zeitraum (kein Bankabruf) wird keine Vormerkung storniert")
    func pipelineWithoutWindowNeverCancels() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let pipeline = ImportPipeline(
            providers: [],
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )
        let accountID = UUID()
        func imported(_ amount: Decimal, pending: Bool, merchant: String) -> ImportedTransaction {
            ImportedTransaction(
                status: pending ? .pending : .booked,
                kind: .purchase,
                amount: Money(amount: amount, currency: .eur),
                bookedAt: pending ? nil : daysAgo(1),
                authorizedAt: pending ? daysAgo(2) : nil,
                rawDescription: merchant,
                rawMerchantName: merchant
            )
        }
        _ = try await pipeline.commitParsedTransactions(
            [imported(-50, pending: true, merchant: "HOTEL")],
            source: .openBanking, providerIdentifier: "test", into: accountID
        )
        _ = try await pipeline.commitParsedTransactions(
            [imported(-5, pending: false, merchant: "KIOSK")],
            source: .openBanking, providerIdentifier: "test", into: accountID
        )
        let rows = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(rows.first { $0.amount.amount == -50 }?.status == .pending)
    }

    @Test("Statuswechsel: vorgemerkt wird gebucht oder storniert, gebucht nie wieder vorgemerkt")
    func statusTransitions() {
        #expect(TransactionStatus.pending.canTransition(to: .booked))
        #expect(TransactionStatus.pending.canTransition(to: .cancelled))
        #expect(TransactionStatus.cancelled.canTransition(to: .booked))
        #expect(TransactionStatus.cancelled.canTransition(to: .pending))
        #expect(TransactionStatus.booked.canTransition(to: .reversed))
        #expect(TransactionStatus.booked.canTransition(to: .booked))
        #expect(!TransactionStatus.booked.canTransition(to: .pending))
        #expect(!TransactionStatus.booked.canTransition(to: .cancelled))
        #expect(!TransactionStatus.reversed.canTransition(to: .booked))
    }
}
