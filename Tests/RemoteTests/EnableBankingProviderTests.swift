import Foundation
import Security
import Foundation
import Testing

@testable import FinanceTracker

/// Enable Banking Provider (WP: GoCardless-Ersatz: Sign-ups pausiert).
///
/// Fixtures (Tests/Fixtures/enablebanking-test-*): WEGWERF-Test-Keys
/// kein echtes Secret.
@Suite("EnableBankingProvider")
struct EnableBankingProviderTests {

    private static let fixturePEM = EnableBankingTestKeys.privatePEM

    private static func base64URLDecode(_ string: String) -> Data {
        var value = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)!
    }

    // MARK: - JWT Signer

    @Test("JWT: RS256-Struktur (kid, iss/aud) und Signatur verifizierbar")
    func jwtStructureAndSignature() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_771_000_000)
        let signer = EnableBankingJWTSigner(
            applicationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            privateKeyPEM: Self.fixturePEM
        ) { fixedNow }

        let token = try signer.makeToken()
        let segments = token.split(separator: ".").map(String.init)
        #expect(segments.count == 3)

        let headerJSON = String(data: Self.base64URLDecode(segments[0]), encoding: .utf8) ?? ""
        #expect(headerJSON.contains("\"alg\":\"RS256\""))
        #expect(headerJSON.contains("\"kid\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\""))

        let payloadJSON = String(data: Self.base64URLDecode(segments[1]), encoding: .utf8) ?? ""
        #expect(payloadJSON.contains("\"iss\":\"enablebanking.com\""))
        #expect(payloadJSON.contains("\"aud\":\"api.enablebanking.com\""))
        #expect(payloadJSON.contains("\"iat\":\(Int(fixedNow.timeIntervalSince1970))"))
        #expect(payloadJSON.contains("\"exp\":\(Int(fixedNow.timeIntervalSince1970) + 3600)"))

        // Signatur verifizieren: Beweis, dass die RS256-Signatur kryptographisch stimmt.
        let signingInput = "\(segments[0]).\(segments[1])"
        let signature = Self.base64URLDecode(segments[2]) as CFData
        let key = try EnableBankingJWTSigner.loadPrivateKey(pem: Self.fixturePEM)
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        var verifyError: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            signature,
            &verifyError
        )
        #expect(verified, "RS256-Signatur muss mit dem Fixture-Public-Key verifizierbar sein")
    }

    @Test("JWT-Signer: kaputter PEM wirft kontrollierten Fehler")
    func invalidPEMThrows() {
        #expect(throws: EnableBankingJWTSigner.SignerError.self) {
            try EnableBankingJWTSigner.loadPrivateKey(pem: "kein schlüssel")
        }
    }

    @Test("PKCS#8-Erkennung und PKCS#1-Extraktion aus dem Fixture")
    func pkcs8Extraction() throws {
        let der = try EnableBankingJWTSigner.derFromPEM(Self.fixturePEM)
        #expect(EnableBankingJWTSigner.isPKCS8(der: der))
        let key = try EnableBankingJWTSigner.loadPrivateKey(pem: Self.fixturePEM)
        let attributes = SecKeyCopyAttributes(key) as? [CFString: Any]
        let keyType = attributes?[kSecAttrKeyType] as? String
        #expect(keyType == (kSecAttrKeyTypeRSA as String))
    }

    // MARK: - Session-Status-Mapping (Rule 16)

    @Test("Session-Status: AUTHORIZED→ready, PDNG→pending, EXPIRED→expired, REVOKED→failed")
    func sessionStatusMapping() {
        #expect(EnableBankingBankDataProvider.mapSessionStatus("AUTHORIZED") == .ready)
        #expect(EnableBankingBankDataProvider.mapSessionStatus("pending_authorization") == .pending)
        #expect(EnableBankingBankDataProvider.mapSessionStatus("RETURNED_FROM_BANK") == .pending)
        #expect(EnableBankingBankDataProvider.mapSessionStatus("EXPIRED") == .expired)
        #expect(EnableBankingBankDataProvider.mapSessionStatus("REVOKED") == .failed)
        #expect(EnableBankingBankDataProvider.mapSessionStatus("SOMETHINGNEW") == .unknown("SOMETHINGNEW"))
    }

    // MARK: - Vorabprüfung & Consent (Production-Banklauf)

    private struct SingleResponseTransport: HTTPTransport {
        let json: String
        let status: Int
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func provider(json: String, status: Int = 200) -> EnableBankingBankDataProvider {
        EnableBankingBankDataProvider(redirectURL: "https://enablebanking.com/redirect", transport: SingleResponseTransport(json: json, status: status)) {
            EnableBankingCredentials(applicationID: "test-application", privateKeyPEM: Self.fixturePEM)
        }
    }

    @Test("GET /application: Umgebung, Aktivierung und Redirect-URLs werden normalisiert")
    func applicationInfoDecoding() async throws {
        let info = try await provider(json: #"{"name":"FinanceTracker Prod","environment":"PRODUCTION","redirect_urls":["https://enablebanking.com/redirect"],"active":true,"countries":["DE","AT"],"services":["AIS"]}"#).applicationInfo()
        #expect(info.name == "FinanceTracker Prod")
        #expect(info.environment == .production)
        #expect(info.isActive)
        #expect(info.redirectURLs == ["https://enablebanking.com/redirect"])
        #expect(info.countries == ["DE", "AT"])
        #expect(EnableBankingBankDataProvider.environment(fromString: "sandbox") == .sandbox)
        #expect(EnableBankingBankDataProvider.environment(fromString: nil) == .unknown(""))
    }

    @Test("GET /application: HTTP 401 bleibt ein sichtbarer Provider-Fehler")
    func applicationInfoRejected() async {
        await #expect(throws: BankProviderError.self) {
            _ = try await provider(json: #"{"detail":"Unauthorized"}"#, status: 401).applicationInfo()
        }
    }

    @Test("Consent-Dauer: 90 Tage angestrebt, Bank-Maximum kappt, ohne Maximum 10 Tage")
    func consentDays() {
        #expect(EnableBankingBankDataProvider.consentDays(maximumSeconds: 15_552_000) == 90)   // 180 Tage erlaubt
        #expect(EnableBankingBankDataProvider.consentDays(maximumSeconds: 7_776_000) == 90)    // genau 90
        #expect(EnableBankingBankDataProvider.consentDays(maximumSeconds: 2_592_000) == 30)    // 30 Tage erlaubt
        #expect(EnableBankingBankDataProvider.consentDays(maximumSeconds: 3_600) == 1)
        #expect(EnableBankingBankDataProvider.consentDays(maximumSeconds: nil) == 10)
        #expect(EnableBankingBankDataProvider.consentDays(maximumSeconds: 0) == 10)
    }

    @Test("Session: valid_until mit Mikrosekunden und Offset wird gelesen")
    func sessionValidUntilParsing() async throws {
        let state = try await provider(json: #"{"status":"AUTHORIZED","accounts":["a"],"access":{"valid_until":"2026-09-30T12:00:00.000000+00:00"}}"#).connectionStatus(connectionID: "s")
        #expect(state.authorization == .ready)
        #expect(state.consentValidUntil == ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z"))
        #expect(EnableBankingBankDataProvider.dateTime(fromString: "2026-01-02T03:04:05Z") == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        #expect(EnableBankingBankDataProvider.dateTime(fromString: "2026-01-02T03:04:05.123+02:00") == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05+02:00"))
        #expect(EnableBankingBankDataProvider.dateTime(fromString: nil) == nil)
        #expect(EnableBankingBankDataProvider.dateTime(fromString: "garbage") == nil)
    }

    // MARK: - Transaction-Mapping (Rule 16/17)

    private func decode(_ json: String) throws -> EnableBankingTransaction {
        try JSONDecoder().decode(EnableBankingTransaction.self, from: Data(json.utf8))
    }

    @Test("Mapping: DBIT → negativ, CRDT → positiv; externalID = UID + entry_reference")
    func debitCreditSigns() throws {
        let debitJSON = """
        {
            "entry_reference": "5561990681",
            "transaction_amount": {"amount": "43.27", "currency": "EUR"},
            "credit_debit_indicator": "DBIT",
            "status": "BOOK",
            "booking_date": "2026-08-10",
            "creditor": {"name": "REWE MARKT"},
            "remittance_information": ["Wocheneinkauf"]
        }
        """
        let debit = try #require(EnableBankingBankDataProvider.map(
            transaction: decode(debitJSON),
            accountUID: "acc-1"
        ))
        #expect(debit.amount.amount == Decimal(string: "-43.27")!)
        #expect(debit.amount.currency == .eur)
        #expect(debit.state == .booked)
        #expect(debit.creditorName == "REWE MARKT")
        #expect(debit.remittanceInformation == "Wocheneinkauf")
        #expect(debit.externalID == "eb-5561990681")

        let creditJSON = """
        {
            "entry_reference": "100",
            "transaction_amount": {"amount": "2850.00", "currency": "EUR"},
            "credit_debit_indicator": "CRDT",
            "status": "BOOK",
            "booking_date": "2026-08-28",
            "debtor": {"name": "Acme GmbH"}
        }
        """
        let credit = try #require(EnableBankingBankDataProvider.map(
            transaction: decode(creditJSON),
            accountUID: "acc-1"
        ))
        #expect(credit.amount.amount == Decimal(string: "2850.00")!)
        #expect(credit.creditorName == nil)
        #expect(credit.debtorName == "Acme GmbH")
    }

    @Test("Mapping: PDNG → pending; fehlender entry_reference → externalID nil (kein Fake-Dedup)")
    func pendingAndMissingEntryReference() throws {
        let pendingJSON = """
        {
            "transaction_amount": {"amount": "5.00", "currency": "EUR"},
            "credit_debit_indicator": "DBIT",
            "status": "PDNG",
            "value_date": "2026-08-28"
        }
        """
        let mapped = try #require(EnableBankingBankDataProvider.map(
            transaction: decode(pendingJSON),
            accountUID: "acc-9"
        ))
        #expect(mapped.state == .pending)
        #expect(mapped.externalID == nil)
    }

    @Test("Mapping: fehlender CRDT/DBIT-Indikator → ungültiger Datensatz (Rule 17)")
    func missingIndicatorRejected() throws {
        let brokenJSON = """
        {
            "entry_reference": "1",
            "transaction_amount": {"amount": "5.00", "currency": "EUR"},
            "status": "BOOK"
        }
        """
        let dto = try decode(brokenJSON)
        #expect(EnableBankingBankDataProvider.map(
            transaction: dto,
            accountUID: "acc-1"
        ) == nil)
    }

    @Test("Institution-ID-Roundtrip: Name+Land codieren/decodieren")
    func institutionIDRoundtrip() {
        let id = EnableBankingBankDataProvider.institutionID(name: "Mock ASPSP", country: "DE")
        #expect(id == "DE|Mock ASPSP")
        let aspsp = EnableBankingBankDataProvider.aspsp(fromInstitutionID: id)
        #expect(aspsp?.name == "Mock ASPSP")
        #expect(aspsp?.country == "DE")
    }

    private actor PageTransport: HTTPTransport {
        let pages: [String]
        let details: String
        private var requests: [URLRequest] = []
        private var pageIndex = 0

        init(pages: [String], details: String = #"{"currency":"EUR"}"#) {
            self.pages = pages
            self.details = details
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let url = try #require(request.url)
            let json: String
            if url.path.hasSuffix("/details") {
                json = details
            } else {
                guard pageIndex < pages.count else {
                    throw BankProviderError.invalidResponse(endpoint: url.path)
                }
                json = pages[pageIndex]
                pageIndex += 1
            }
            return (Data(json.utf8), try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil
            )))
        }

        func transactionQueries() -> [[URLQueryItem]] {
            requests.filter { $0.url?.path.hasSuffix("/transactions") == true }.map {
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            }
        }
    }

    private func provider(_ transport: PageTransport) -> EnableBankingBankDataProvider {
        EnableBankingBankDataProvider(redirectURL: "https://example.com/redirect", transport: transport) {
            EnableBankingCredentials(applicationID: "test-application", privateKeyPEM: Self.fixturePEM)
        }
    }

    private static let validTransaction = #"{"entry_reference":"1","transaction_amount":{"amount":"5.00","currency":"EUR"},"credit_debit_indicator":"DBIT","status":"BOOK","booking_date":"2026-01-02"}"#

    @Test("Abruf: alle Seiten einschließlich leerer Zwischenseite, Filter bleiben erhalten")
    func paginatedTransactions() async throws {
        let transport = PageTransport(pages: [
            "{\"transactions\":[\(Self.validTransaction)],\"continuation_key\":\"next/+?\"}",
            #"{"transactions":[],"continuation_key":"last"}"#,
            "{\"transactions\":[\(Self.validTransaction.replacingOccurrences(of: "\"1\"", with: "\"2\""))],\"continuation_key\":null}"
        ])
        let date = try #require(ISO8601DateFormatter().date(from: "2026-01-02T00:30:00Z"))
        let result = try await provider(transport).fetchAccountData(accountID: "account", dateFrom: date)
        #expect(result.transactions.map(\.externalID) == ["eb-1", "eb-2"])
        let queries = await transport.transactionQueries()
        #expect(queries.count == 3)
        #expect(queries.allSatisfy { $0.contains(URLQueryItem(name: "date_from", value: "2026-01-02")) })
        #expect(!queries[0].contains { $0.name == "continuation_key" })
        #expect(queries[1].contains(URLQueryItem(name: "continuation_key", value: "next/+?")))
        #expect(queries[2].contains(URLQueryItem(name: "continuation_key", value: "last")))
    }

    @Test("Abruf: wiederholter Seiten-Schlüssel wird als Fehler gemeldet")
    func repeatingPageRejected() async throws {
        let transport = PageTransport(pages: [
            #"{"transactions":[],"continuation_key":"loop"}"#,
            #"{"transactions":[],"continuation_key":"loop"}"#
        ])
        await #expect(throws: BankProviderError.invalidResponse(endpoint: "/accounts/account/transactions")) {
            try await provider(transport).fetchAccountData(accountID: "account", dateFrom: nil)
        }
        #expect(await transport.transactionQueries().count == 2)
    }

    @Test("Abruf: ungültige Zeile auf Folgeseite darf keinen Teilimport liefern")
    func invalidRowRejectsWholeFetch() async throws {
        let invalid = Self.validTransaction.replacingOccurrences(of: "DBIT", with: "unknown")
        let transport = PageTransport(pages: [
            "{\"transactions\":[\(Self.validTransaction)],\"continuation_key\":\"next\"}",
            "{\"transactions\":[\(invalid)]}"
        ])
        await #expect(throws: BankProviderError.invalidResponse(endpoint: "/accounts/account/transactions")) {
            try await provider(transport).fetchAccountData(accountID: "account", dateFrom: nil)
        }
    }

    @Test("Abruf: fehlende Umsatzliste ist kein leeres Konto")
    func missingTransactionsRejected() async throws {
        let transport = PageTransport(pages: [#"{"continuation_key":null}"#])
        await #expect(throws: DecodingError.self) {
            try await provider(transport).fetchAccountData(accountID: "account", dateFrom: nil)
        }
    }

    @Test("Abruf: fehlende Kontowährung wird nicht durch EUR ersetzt")
    func missingCurrencyRejected() async throws {
        let transport = PageTransport(pages: [], details: "{}")
        await #expect(throws: BankProviderError.invalidResponse(endpoint: "/accounts/account/details")) {
            try await provider(transport).fetchAccountData(accountID: "account", dateFrom: nil)
        }
        #expect(await transport.transactionQueries().isEmpty)
    }

    @Test("Mapping: ungültige Beträge werden vollständig abgelehnt", arguments: ["5oops", "-5.00", "5,00", "", "NaN", #"5.00\n"#])
    func invalidAmountsRejected(_ amount: String) throws {
        let dto = try decode(Self.validTransaction.replacingOccurrences(of: "5.00", with: amount))
        #expect(EnableBankingBankDataProvider.map(transaction: dto, accountUID: "account") == nil)
    }

    @Test("Mapping: unbekannte, stornierte und abgelehnte Status sind keine Buchungen", arguments: ["CNCL", "RJCT", "OTHR", "UNKNOWN"])
    func unsupportedStatusRejected(_ status: String) throws {
        let dto = try decode(Self.validTransaction.replacingOccurrences(of: "BOOK", with: status))
        #expect(EnableBankingBankDataProvider.map(transaction: dto, accountUID: "account") == nil)
    }

    @Test("Mapping: geplanter Umsatz wird als ausstehend normalisiert")
    func scheduledIsPending() throws {
        let dto = try decode(Self.validTransaction.replacingOccurrences(of: "BOOK", with: "SCHD"))
        #expect(EnableBankingBankDataProvider.map(transaction: dto, accountUID: "account")?.state == .pending)
    }
}
