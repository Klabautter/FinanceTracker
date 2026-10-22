import Foundation
import Testing

@testable import FinanceTracker

// MARK: - Probe: Import-Provider mit Thread-Aufzeichnung (P0)

/// Zeichnet auf, ob `canHandle`/`parse` auf dem Main-Thread liefen.
/// Vor dem Fix lief `ImportPipeline.prepare` via `ImportModel` auf Main;
/// nach dem Fix läuft es in `Task.detached` (Hintergrund).
private final class ImportThreadProbeProvider: ImportProvider, @unchecked Sendable {
    let identifier = "probe_thread_csv"
    let displayName = "Thread-Probe"
    let transactionSource: TransactionSource = .genericCSV

    private let lock = NSLock()
    private var _canHandleOnMain: Bool?
    private var _parseOnMain: Bool?

    private nonisolated func recordCanHandle() {
        let onMain = Thread.isMainThread
        lock.lock(); defer { lock.unlock() }
        _canHandleOnMain = onMain
    }

    private nonisolated func recordParse() {
        let onMain = Thread.isMainThread
        lock.lock(); defer { lock.unlock() }
        _parseOnMain = onMain
    }

    var canHandleOnMain: Bool? {
        lock.lock(); defer { lock.unlock() }
        return _canHandleOnMain
    }

    var parseOnMain: Bool? {
        lock.lock(); defer { lock.unlock() }
        return _parseOnMain
    }

    func canHandle(_ file: ImportFile) async throws -> Bool {
        recordCanHandle()
        return true
    }

    func parse(_ file: ImportFile) async throws -> ProviderParseResult {
        recordParse()
        return ProviderParseResult(
            totalRows: 1,
            transactions: [
                ImportedTransaction(
                    externalID: "probe-1",
                    amount: Money(amount: Decimal(string: "-9.99")!, currency: .eur),
                    bookedAt: Date(timeIntervalSince1970: 1_786_000_000),
                    rawDescription: "Probe",
                    rawMerchantName: "Probe",
                    merchantDisplayName: "Probe"
                )
            ],
            issues: []
        )
    }
}

// MARK: - Probe: Bank-Provider mit Thread-Aufzeichnung (P0)

/// Minimaler Bank-Provider, der den Thread von `fetchAccountData` aufzeichnet.
/// Vor dem Fix (`@MainActor BankSyncService`) lief der Fetch auf Main;
/// nach dem Fix läuft er in `Task.detached` (Hintergrund).
private final class SyncThreadRecordingProvider: BankDataProvider, @unchecked Sendable {
    var identifier: String = "probe_bank"
    var displayName: String = "Probe Bank"

    private let lock = NSLock()
    private var _fetchOnMain: Bool?
    private nonisolated func recordFetch() {
        let onMain = Thread.isMainThread
        lock.lock(); defer { lock.unlock() }
        _fetchOnMain = onMain
    }
    var fetchOnMain: Bool? {
        lock.lock(); defer { lock.unlock() }
        return _fetchOnMain
    }

    private let calendar = Calendar(identifier: .gregorian)

    func institutions(country: String) async throws -> [BankInstitution] { [] }

    func createConnection(institutionID: String, redirectURL: URL?) async throws -> (connectionID: String, authorizationURL: URL?) {
        ("probe-connection-1", nil)
    }

    func connectionStatus(connectionID: String) async throws -> RemoteConnectionState {
        RemoteConnectionState(linkedAccountIDs: ["acc-probe"], authorization: .ready)
    }

    func authorizeSession(code: String) async throws -> String { "probe-session" }

    func fetchAccountData(accountID: String, dateFrom: Date?) async throws -> RemoteBankAccountData {
        recordFetch()
        let account = RemoteBankAccount(
            id: "acc-probe",
            providerAccountID: "acc-probe",
            ownerName: "Probe Nutzer",
            maskedIBAN: "•••• 1111",
            currency: .eur
        )
        let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20))
        return RemoteBankAccountData(
            account: account,
            transactions: [
                RemoteBankTransaction(
                    externalID: "probe-T1",
                    state: .booked,
                    amount: Money(amount: Decimal(string: "-12.50")!, currency: .eur),
                    bookingDate: day,
                    valueDate: day,
                    creditorName: "PROBE MARKT",
                    debtorName: nil,
                    remittanceInformation: "Probe Zahlung 1"
                ),
                RemoteBankTransaction(
                    externalID: "probe-T2",
                    state: .booked,
                    amount: Money(amount: Decimal(string: "100.00")!, currency: .eur),
                    bookingDate: day,
                    valueDate: day,
                    creditorName: nil,
                    debtorName: "Arbeitgeber",
                    remittanceInformation: "Probe Zahlung 2"
                )
            ]
        )
    }
}

@MainActor
@Suite("Import Off-Main (P0)")
struct ImportOffMainTests {
    @Test("prepareFile parst im Hintergrund, Phase wird reviewing")
    func prepareRunsInBackground() async throws {
        let probe = ImportThreadProbeProvider()
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(
            container: store.container,
            baseCurrency: .eur,
            importProviders: [probe]
        )
        try await dependencies.accountRepository.upsert([
            Account(name: "Probe-Konto", type: .checking, currency: .eur, source: .csvImport)
        ])
        let model = ImportModel(dependencies: dependencies)
        await model.loadAccounts()
        try #require(model.selectedAccountID != nil)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).csv")
        try "Date,Memo,Amount\n2026-08-05,Probe,-9.99\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        await model.prepareFile(at: url)

        guard case .reviewing = model.phase else {
            Issue.record("Expected reviewing, got \(model.phase)")
            return
        }
        #expect(probe.canHandleOnMain == false, "Provider-Erkennung darf nicht auf Main laufen")
        #expect(probe.parseOnMain == false, "Parsing/Fingerprint-Loop darf nicht auf Main laufen")
    }
}

@MainActor
@Suite("BankSync Off-Main (P0)")
struct BankSyncOffMainTests {
    @Test("sync fetcht und committet im Hintergrund, Ergebnis korrekt")
    func syncRunsInBackground() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let provider = SyncThreadRecordingProvider()
        let service = BankSyncService(dependencies: dependencies, provider: provider)
        let connection = try await service.connect(
            institution: BankInstitution(id: "PROBE", name: "Probe", bic: nil, transactionTotalDays: 90),
            providerConnectionID: "probe-req-1",
            linkedAccountIDs: []
        )

        let result = try await service.sync(connection: connection)

        #expect(result.accountsSynced == 1)
        #expect(result.importedCount == 2)
        #expect(provider.fetchOnMain == false, "Fetch-Loop darf nicht auf Main laufen")
        #expect(try await dependencies.transactionRepository.count() == 2)
    }

    @Test("sync ist off-main aufrufbar (Mock-Provider, Refactor-Regression)")
    func syncWorksFromBackgroundTask() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let provider = MockBankDataProvider()
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20))
        provider.stubbedTransactions = [
            RemoteBankTransaction(
                externalID: "bg-T1",
                state: .booked,
                amount: Money(amount: Decimal(string: "-5.00")!, currency: .eur),
                bookingDate: day,
                valueDate: day,
                creditorName: "BG MARKT",
                debtorName: nil,
                remittanceInformation: "Hintergrund-Sync"
            )
        ]
        let service = BankSyncService(dependencies: dependencies, provider: provider)
        let connection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "bg-req-1",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )

        let result = try await Task.detached(priority: .userInitiated) {
            try await service.sync(connection: connection)
        }.value

        #expect(result.accountsSynced == 1)
        #expect(result.importedCount == 1)
        #expect(try await dependencies.transactionRepository.count() == 1)
    }
}
