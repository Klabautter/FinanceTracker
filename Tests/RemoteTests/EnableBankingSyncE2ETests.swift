import Foundation
import Testing

@testable import FinanceTracker

/// Rule 25: Provider→Pipeline→Repository E2E für jeden Provider.
/// Enable Banking mit Stub-Transport: kompletter Sync-Pfad: Code-Exchange,
/// Session-Status, Import, Merchant-Normalisierung, Duplikat-Erkennung.
@MainActor
@Suite("EnableBankingSyncE2E")
struct EnableBankingSyncE2ETests {

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    /// Fixierter Stub-Transport: liefert je (Methode, Pfad) die Payloads.
    private struct StubTransport: HTTPTransport {
        var responses: [String: (Data, Int)]

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let key = "\(request.httpMethod ?? "GET") \(path)"
            guard let (data, status) = responses[key] else {
                throw BankProviderError.invalidResponse(endpoint: key)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }
    }

    private static func json(_ text: String) -> Data {
        Data(text.utf8)
    }

    private static let sessionID = "11111111-2222-3333-4444-555555555555"
    private static let accountUID = "9aaaaaaa-0000-0000-0000-000000000001"

    private static let sessionAuthorizedJSON = """
    {
        "status": "AUTHORIZED",
        "accounts": ["\(accountUID)"],
        "accounts_data": [],
        "aspsp": {"name": "Mock ASPSP", "country": "DE"},
        "psu_type": "personal",
        "psu_id_hash": "abc",
        "access": {"valid_until": "2026-09-30T12:00:00.000000+00:00"},
        "created": "2026-08-29T12:00:00.000000+00:00"
    }
    """

    private static let accountDetailsJSON = """
    {
        "uid": "\(accountUID)",
        "currency": "EUR",
        "name": "Max Mustermann",
        "account_id": {"scheme_name": "IBAN", "identification": "DE02120300000000202051"},
        "identification_hash": "hash-1"
    }
    """

    private static let transactionsJSON = """
    {
        "transactions": [
            {
                "entry_reference": "5561990681",
                "transaction_amount": {"amount": "43.27", "currency": "EUR"},
                "credit_debit_indicator": "DBIT",
                "status": "BOOK",
                "booking_date": "2026-08-10",
                "creditor": {"name": "REWE MARKT"},
                "remittance_information": ["Wocheneinkauf"]
            },
            {
                "entry_reference": "5561990699",
                "transaction_amount": {"amount": "6.50", "currency": "EUR"},
                "credit_debit_indicator": "DBIT",
                "status": "PDNG",
                "value_date": "2026-08-28",
                "creditor": {"name": "MCDONALDS 155"}
            },
            {
                "entry_reference": "5561990700",
                "transaction_amount": {"amount": "2850.00", "currency": "EUR"},
                "credit_debit_indicator": "CRDT",
                "status": "BOOK",
                "booking_date": "2026-08-28",
                "debtor": {"name": "Acme GmbH"},
                "remittance_information": ["Gehalt August"]
            }
        ]
    }
    """

    private func makeProvider(credentials: EnableBankingCredentials) -> EnableBankingBankDataProvider {
        EnableBankingBankDataProvider(
            redirectURL: "https://example.com/redirect",
            transport: StubTransport(responses: [
                "POST /sessions": (
                    Self.json("""
                    {
                        "session_id": "\(Self.sessionID)",
                        "accounts": [
                            {
                                "uid": "\(Self.accountUID)",
                                "currency": "EUR",
                                "name": "Max Mustermann",
                                "account_id": {"scheme_name": "IBAN", "identification": "DE02120300000000202051"}
                            }
                        ],
                        "aspsp": {"name": "Mock ASPSP", "country": "DE"}
                    }
                    """), 200)
                ,
                "GET /sessions/\(Self.sessionID)": (Self.json(Self.sessionAuthorizedJSON), 200),
                "GET /accounts/\(Self.accountUID)/details": (Self.json(Self.accountDetailsJSON), 200),
                "GET /accounts/\(Self.accountUID)/transactions": (Self.json(Self.transactionsJSON), 200)
            ])
        ) { credentials }
    }

    @Test("E2E: Code-Exchange → Sync → Import; zweiter Sync = alle Duplikate")
    func fullSyncPipelineWithDedup() async throws {
        let dependencies = try makeDependencies()
        let defaultsSuite = "EnableBankingSyncE2E-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        await SystemCatalogSeeder(dependencies: dependencies, defaults: defaults).seedIfNeeded()
        let credentials = EnableBankingCredentials(
            applicationID: "app-1",
            privateKeyPEM: EnableBankingTestKeys.privatePEM
        )
        let provider = makeProvider(credentials: credentials)

        // 1) Code-Exchange (Redirect-URL mit ?code= → Session-ID).
        let redirect = "https://example.com/redirect?state=x&code=abc123"
        let components = URLComponents(string: redirect)!
        let code = try #require(components.queryItems?.first(where: { $0.name == "code" })?.value)
        let sessionID = try await provider.authorizeSession(code: code)
        #expect(sessionID == Self.sessionID)

        // 2) Sync #1: kompletter Import.
        let service = BankSyncService(dependencies: dependencies, provider: provider)
        let institution = BankInstitution(
            id: EnableBankingBankDataProvider.institutionID(name: "Mock ASPSP", country: "DE"),
            name: "Mock ASPSP",
            bic: nil,
            transactionTotalDays: 90
        )
        let connection = try await service.connect(
            institution: institution,
            providerConnectionID: sessionID,
            linkedAccountIDs: [],
            providerRaw: .enablebanking
        )
        let first = try await service.sync(connection: connection)
        #expect(first.accountsSynced == 1)
        #expect(first.importedCount == 3)
        #expect(first.duplicateCount == 0)
        #expect(try await dependencies.transactionRepository.count() == 3)

        // Das tatsächliche Zustimmungs-Ende der Session landet an der
        // Verbindung (Quelle der Ablauf-Warnung vor der Re-Autorisierung).
        let stored = try #require(try await dependencies.connectionRepository.connections().first)
        #expect(stored.consentExpiresAt == ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z"))

        // 3) Sync #2 (Overlap-Fenster): ALLE als Duplikate erkannt (Rule 20:
        //    Dedup über externalID = Account-UID + entry_reference).
        let second = try await service.sync(connection: connection)
        #expect(second.importedCount == 0)
        #expect(second.duplicateCount == 3)

        // 4) Pipeline-Korrektheit in der Persistenz.
        let transactions = try await dependencies.transactionRepository.transactions(
            matching: TransactionQuery()
        )
        #expect(transactions.count == 3)
        #expect(transactions.contains { txn in
            txn.amount.amount == Decimal(string: "-43.27")!
                && txn.effectiveMerchantName == "REWE"
                && txn.merchantID != nil
                && txn.categoryID == Category.groceries.id
                && txn.status == .booked
        })
        #expect(transactions.contains { txn in
            txn.amount.amount == Decimal(string: "-6.50")!
                && txn.effectiveMerchantName == "McDonald's"
                && txn.merchantID != nil
                && txn.categoryID == Category.restaurants.id
                && txn.status == .pending
        })
        #expect(transactions.contains { txn in
            txn.amount.amount == Decimal(string: "2850.00")!
                && txn.effectiveMerchantName == "Acme"
                && txn.merchantID != nil
                && txn.categoryID == Category.income.id
        })

        // 5) Analytics konsumiert dieselben Daten (Rule 25).
        let calculator = AnalyticsCalculator(baseCurrency: .eur)
        let snapshot = calculator.snapshot(transactions: transactions, categories: [], calendar: .current)
        #expect(snapshot.totalSpending == Decimal(string: "49.77")!) // 43.27 + 6.50
    }

}
