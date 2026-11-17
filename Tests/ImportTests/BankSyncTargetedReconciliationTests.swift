import Foundation
import Testing

@testable import FinanceTracker

/// Roadmap 3.3: Der Bankabruf gleicht gezielt ab (Datumsfenster der Antwort,
/// gemeldete Bank-IDs, offene Vormerkungen) und lädt dafür weder das Konto
/// noch den ganzen Bestand.
@Suite("BankSyncTargetedReconciliation")
struct BankSyncTargetedReconciliationTests {
    /// Zählt Ladevorgänge ohne Grenze: Abfragen ohne Zeitraum, den
    /// Kontobestand einer Quelle und die leichte Projektion über alles.
    final class UnboundedLoadRecorder: TransactionRepository, @unchecked Sendable {
        let base: any TransactionRepository
        private let lock = NSLock()
        private var unbounded: [String] = []
        var unboundedLoads: [String] { lock.withLock { unbounded } }
        func reset() { lock.withLock { unbounded = [] } }
        private func record(_ what: String) { lock.withLock { unbounded.append(what) } }

        init(base: any TransactionRepository) { self.base = base }

        func transactions(matching query: TransactionQuery) async throws -> [Transaction] {
            if query.dateInterval == nil { record("transactions(matching:) ohne Zeitraum") }
            return try await base.transactions(matching: query)
        }
        func transactions(accountID: UUID, source: TransactionSource) async throws -> [Transaction] {
            record("transactions(accountID:source:)")
            return try await base.transactions(accountID: accountID, source: source)
        }
        func reviewCandidateTransactions() async throws -> [Transaction] {
            record("reviewCandidateTransactions")
            return try await base.reviewCandidateTransactions()
        }
        func lightTransactionSlices() -> AsyncThrowingStream<[Transaction], Error> {
            record("lightTransactionSlices")
            return base.lightTransactionSlices()
        }
        func accountMovementRows() async throws -> [AccountMovementRow] {
            record("accountMovementRows")
            return try await base.accountMovementRows()
        }
        // Gezielte Abfragen: unverändert an das echte Repository.
        func reconciliationCandidates(
            accountID: UUID, window: DateInterval?, externalIDs: Set<String>, statuses: Set<TransactionStatus>
        ) async throws -> [Transaction] {
            try await base.reconciliationCandidates(accountID: accountID, window: window, externalIDs: externalIDs, statuses: statuses)
        }
        func transactions(
            accountID: UUID, source: TransactionSource, uncategorizedOrIn categoryIDs: Set<FinanceTracker.Category.ID>
        ) async throws -> [Transaction] {
            try await base.transactions(accountID: accountID, source: source, uncategorizedOrIn: categoryIDs)
        }
        func transactions(ids: Set<UUID>) async throws -> [Transaction] { try await base.transactions(ids: ids) }
        func transactionPage(
            matching query: TransactionQuery, sort: TransactionSortOrder, offset: Int, limit: Int
        ) async throws -> TransactionPage {
            try await base.transactionPage(matching: query, sort: sort, offset: offset, limit: limit)
        }
        func recentTransactions(limit: Int) async throws -> [Transaction] { try await base.recentTransactions(limit: limit) }
        func transaction(id: UUID) async throws -> Transaction? { try await base.transaction(id: id) }
        func upsert(_ transactions: [Transaction]) async throws { try await base.upsert(transactions) }
        func deleteTransactions(importBatchID: UUID) async throws { try await base.deleteTransactions(importBatchID: importBatchID) }
        func deleteTransactions(ids: Set<UUID>) async throws { try await base.deleteTransactions(ids: ids) }
        func count() async throws -> Int { try await base.count() }
        func deleteAll() async throws { try await base.deleteAll() }
        func deleteAllDemoTransactions() async throws { try await base.deleteAllDemoTransactions() }
        func assignCategoriesToUncategorized(
            matching rules: [CategoryRule], assignableCategoryIDs: Set<FinanceTracker.Category.ID>
        ) async throws -> Set<UUID> {
            try await base.assignCategoriesToUncategorized(matching: rules, assignableCategoryIDs: assignableCategoryIDs)
        }
        func purgeOrphanedDependents() async throws -> Int { try await base.purgeOrphanedDependents() }
    }

    /// Die Abhängigkeiten des Abrufs, mit dem zählenden Repository.
    struct SyncDependencies: HasAccountRepository, HasBaseCurrency, HasCategoryRepository, HasChangeTracker,
        HasConnectionRepository, HasImportBatchRepository, HasMerchantRepository, HasPreferences,
        HasRuleRepository, HasTransactionAnnotationRepository, HasTransactionRepository {
        let base: AppDependencies
        let transactionRepository: any TransactionRepository
        var accountRepository: any AccountRepository { base.accountRepository }
        var baseCurrency: CurrencyCode { base.baseCurrency }
        var categoryRepository: any CategoryRepository { base.categoryRepository }
        var changeTracker: DataChangeTracker { base.changeTracker }
        var connectionRepository: any ConnectionRepository { base.connectionRepository }
        var importBatchRepository: any ImportBatchRepository { base.importBatchRepository }
        var merchantRepository: any MerchantRepository { base.merchantRepository }
        var preferences: any AppPreferences { base.preferences }
        var ruleRepository: any CategoryRuleRepository { base.ruleRepository }
        var transactionAnnotationRepository: any TransactionAnnotationRepository { base.transactionAnnotationRepository }
    }

    private let calendar = Calendar(identifier: .gregorian)

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func remote(_ id: String, _ amount: String, on date: Date?, pending: Bool = false) -> RemoteBankTransaction {
        RemoteBankTransaction(
            externalID: id,
            state: pending ? .pending : .booked,
            amount: Money(amount: Decimal(string: amount)!, currency: .eur),
            bookingDate: pending ? nil : date,
            valueDate: date,
            creditorName: "REWE MARKT", debtorName: nil, remittanceInformation: "REWE MARKT \(id)"
        )
    }

    private func makeSync() async throws -> (
        service: BankSyncService, provider: MockBankDataProvider, recorder: UnboundedLoadRecorder,
        dependencies: AppDependencies, connection: Connection
    ) {
        let store = try SwiftDataStore(inMemory: true)
        let base = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let recorder = UnboundedLoadRecorder(base: base.transactionRepository)
        let provider = MockBankDataProvider()
        let service = BankSyncService(
            dependencies: SyncDependencies(base: base, transactionRepository: recorder),
            provider: provider
        )
        let connection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "req-1",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )
        return (service, provider, recorder, base, connection)
    }

    @Test("Abruf lädt weder das Konto noch den ganzen Bestand")
    func syncMakesNoUnboundedLoads() async throws {
        let (service, provider, recorder, dependencies, connection) = try await makeSync()
        // Zwei Jahre alter Bestand, der mit der neuen Antwort nichts zu tun hat.
        provider.stubbedTransactions = (1...40).map { remote("OLD\($0)", "-\($0).00", on: day(2024, 1 + $0 % 12, 1 + $0 % 27)) }
        _ = try await service.sync(connection: connection)
        #expect(try await dependencies.transactionRepository.count() == 40)

        recorder.reset()
        provider.stubbedTransactions = [remote("NEW1", "-12.34", on: day(2026, 8, 20))]
        let result = try await service.sync(connection: connection)

        #expect(result.importedCount == 1)
        #expect(recorder.unboundedLoads.isEmpty, "Ungezielte Ladevorgänge: \(recorder.unboundedLoads)")
    }

    @Test("Dieselbe Bank-ID wird auch weit außerhalb des Datumsfensters als Duplikat erkannt")
    func externalIDMatchesOutsideWindow() async throws {
        let (service, provider, _, dependencies, connection) = try await makeSync()
        provider.stubbedTransactions = [remote("SAME", "-43.27", on: day(2026, 3, 2))]
        _ = try await service.sync(connection: connection)

        // Die Bank meldet dieselbe Buchung später mit anderem Datum.
        provider.stubbedTransactions = [
            remote("SAME", "-43.27", on: day(2026, 8, 20)),
            remote("NEW", "-5.00", on: day(2026, 8, 21))
        ]
        let second = try await service.sync(connection: connection)

        #expect(second.importedCount == 1)
        #expect(try await dependencies.transactionRepository.count() == 2)
    }

    @Test("Alte Vormerkung außerhalb des Datumsfensters wird weiterhin storniert, wenn die Bank sie nicht mehr meldet")
    func oldPendingOutsideWindowIsCancelled() async throws {
        let (service, provider, _, dependencies, connection) = try await makeSync()
        provider.stubbedTransactions = [remote("P-GONE", "-7.00", on: day(2026, 6, 2), pending: true)]
        _ = try await service.sync(connection: connection, historyStart: day(2026, 5, 1))
        #expect(try await dependencies.transactionRepository.transactions(matching: TransactionQuery()).first?.status == .pending)

        // Zwei Monate später meldet die Bank ab Mai nur noch eine andere
        // Buchung. Die Vormerkung liegt weit vor dem Fenster dieser Antwort.
        provider.stubbedTransactions = [remote("B-NEW", "-18.30", on: day(2026, 8, 20))]
        let second = try await service.sync(connection: connection, historyStart: day(2026, 5, 1))

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(second.importedCount == 1)
        #expect(stored.count == 2)
        #expect(stored.first { $0.externalID == "P-GONE" }?.status == .cancelled)

        // Meldet die Bank sie später doch gebucht, lebt dieselbe Zeile wieder auf.
        provider.stubbedTransactions = [
            remote("B-NEW", "-18.30", on: day(2026, 8, 20)),
            remote("P-GONE", "-7.00", on: day(2026, 6, 3))
        ]
        _ = try await service.sync(connection: connection, historyStart: day(2026, 5, 1))
        let afterwards = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(afterwards.count == 2)
        #expect(afterwards.first { $0.amount.amount == Decimal(string: "-7.00") }?.status == .booked)
    }

    @Test("Gezielter Bestand: Fenster, Bank-ID und Zustand, jede Buchung einmal")
    func repositoryReturnsTargetedCandidates() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        let other = Account(name: "Zweit", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account, other])
        func txn(_ id: String, _ date: Date, _ status: TransactionStatus = .booked, account accountID: UUID? = nil) -> Transaction {
            Transaction(
                accountID: accountID ?? account.id, source: .openBanking, externalID: id, status: status, kind: .purchase,
                amount: Money(amount: -1, currency: .eur),
                bookedAt: status == .pending ? nil : date, authorizedAt: status == .pending ? date : nil,
                rawDescription: id, rawMerchantName: id, merchantDisplayName: id
            )
        }
        try await dependencies.transactionRepository.upsert([
            txn("in-window", day(2026, 8, 20)),
            txn("by-id", day(2025, 1, 5)),
            txn("old-pending", day(2025, 2, 5), .pending),
            txn("old-booked", day(2025, 3, 5)),
            txn("in-window-and-id", day(2026, 8, 21)),
            txn("other-account", day(2026, 8, 20), account: other.id)
        ])

        let candidates = try await dependencies.transactionRepository.reconciliationCandidates(
            accountID: account.id,
            window: DateInterval(start: day(2026, 8, 1), end: day(2026, 9, 1)),
            externalIDs: ["by-id", "in-window-and-id", "other-account"],
            statuses: [.pending]
        )
        #expect(Set(candidates.compactMap(\.externalID)) == ["in-window", "by-id", "old-pending", "in-window-and-id"])
        #expect(candidates.count == 4)

        let uncategorized = try await dependencies.transactionRepository.transactions(
            accountID: account.id, source: .openBanking, uncategorizedOrIn: [FinanceTracker.Category.transfers.id]
        )
        #expect(uncategorized.count == 5)
    }
}
