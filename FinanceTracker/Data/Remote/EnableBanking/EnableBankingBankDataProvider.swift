import Foundation
import Security

/// Enable Banking Umsetzung des `BankDataProvider`-Protokolls.
///
/// Flow (Enable Banking Quick Start):
/// 1. `GET /aspsps?country=…` → Institutsliste
/// 2. `POST /auth` → Auth-URL; der Nutzer autorisiert in der Bank und
///    landet auf der Redirect-URL mit `?code=…` (die App lässt die URL
///    einfügen: nativer Redirect-Fang ist ein späterer Schritt).
/// 3. `POST /sessions {code}` → session_id + Accounts
/// 4. `GET /sessions/{id}` → Status + Account-UIDs (Sync-Quelle)
/// 5. `GET /accounts/{uid}/details|transactions` → Daten
///
/// Normalisierung: Vorzeichen über
/// `credit_debit_indicator` (CRDT/DBIT), Status über den BOOK/PDNG-Enum,
/// Währung 1:1, externalID stabil aus Account-UID + entry_reference
/// (entry_reference ist NICHT global eindeutig: #20 Dedup-Anforderung).
struct EnableBankingBankDataProvider: BankDataProvider, BankApplicationInfoProviding {
    let identifier: String = ConnectionProvider.enablebanking.rawValue
    let displayName: String = "Enable Banking"

    private var api: APIClient { APIClient(baseURL: EnableBankingAPI.baseURL, transport: transport) }

    private let transport: any HTTPTransport
    private let credentialsProvider: @Sendable () async throws -> EnableBankingCredentials
    /// Bank-Maxima für die Consent-Dauer aus `/aspsps`, damit `/auth` nie mehr
    /// Gültigkeit anfragt, als die Bank erlaubt (sonst HTTP 400).
    private let consentCache = ConsentValidityCache()

    /// Gewünschte Consent-Dauer (PSD2-üblich 90 Tage); die Bank kann weniger
    /// erlauben, dann gilt ihr Maximum.
    static let preferredConsentDays = 90
    /// Ohne bekanntes Bank-Maximum (z. B. Institut nicht über `/aspsps`
    /// geladen) bleibt der konservative Quick-Start-Wert.
    static let fallbackConsentDays = 10

    /// Redirect-URL, die bei der App-Registrierung hinterlegt wurde. Für den
    /// Dev-Flow (URL einfügen) ist der Wert fachlich beliebig, muss aber
    /// zur Whitelist der Anwendung passen.
    let redirectURL: String

    init(
        redirectURL: String,
        transport: any HTTPTransport = URLSessionTransport(),
        credentialsProvider: @escaping @Sendable () async throws -> EnableBankingCredentials
    ) {
        self.redirectURL = redirectURL
        self.transport = transport
        self.credentialsProvider = credentialsProvider
    }

    // MARK: - Auth (RS256-JWT)

    private func jwt() async throws -> String {
        let credentials = try await credentialsProvider()
        let signer = EnableBankingJWTSigner(
            applicationID: credentials.applicationID,
            privateKeyPEM: credentials.privateKeyPEM
        )
        return try signer.makeToken()
    }

    // MARK: - Institutions

    func institutions(country: String) async throws -> [BankInstitution] {
        let data = try await api.send(
            path: "/aspsps",
            method: .get,
            queryItems: [URLQueryItem(name: "country", value: country)],
            bearerToken: try await jwt()
        )
        let decoded = try JSONDecoder().decode(EnableBankingASPSResponse.self, from: data)
        return decoded.aspsps.map { aspsp in
            let id = Self.institutionID(name: aspsp.name, country: aspsp.country)
            consentCache.store(aspsp.maximumConsentValidity, for: id)
            return BankInstitution(
                id: id,
                name: aspsp.name,
                bic: nil,
                transactionTotalDays: aspsp.maximumConsentValidity.map { $0 / 86_400 },
                logoURL: aspsp.logo.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Enable Banking identifiziert ASPSPs über Name+Land (kein institution_id).
    static func institutionID(name: String, country: String) -> String {
        "\(country)|\(name)"
    }

    func institutionDisplayName(forInstitutionID institutionID: String) -> String? {
        Self.aspsp(fromInstitutionID: institutionID)?.name
    }

    static func aspsp(fromInstitutionID id: String) -> (name: String, country: String)? {
        let parts = id.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (name: String(parts[1]), country: String(parts[0]))
    }

    // MARK: - Connection

    /// Enable-Banking-Code-Flow: tauscht den `code` aus der Redirect-URL
    /// gegen die Session-ID (`POST /sessions`). Die autorisierten Accounts
    /// liefert `connectionStatus` über `GET /sessions/{id}`.
    func authorizeSession(code: String) async throws -> String {
        struct AuthorizeRequest: Encodable, Sendable {
            let code: String
        }

        let data = try await api.send(
            path: "/sessions",
            method: .post,
            body: AuthorizeRequest(code: code),
            bearerToken: try await jwt()
        )
        let decoded = try JSONDecoder().decode(EnableBankingAuthorizeSessionResponse.self, from: data)
        return decoded.sessionId
    }

    func createConnection(institutionID: String, redirectURL: URL?) async throws -> (connectionID: String, authorizationURL: URL?) {
        guard let aspsp = Self.aspsp(fromInstitutionID: institutionID) else {
            throw BankProviderError.invalidResponse(endpoint: "/auth")
        }

        // Consent-Dauer: 90 Tage angestrebt, gekappt auf das Bank-Maximum aus
        // `/aspsps`; die tatsächliche Gültigkeit meldet danach die Session.
        // Ist das Maximum noch unbekannt (z. B. Neuanmeldung einer bestehenden
        // Verbindung ohne geladene Bankliste), wird es vorher nachgeladen:
        // sonst bliebe nur der knappe Rückfallwert.
        if consentCache.seconds(for: institutionID) == nil {
            _ = try? await institutions(country: aspsp.country)
        }
        let days = Self.consentDays(maximumSeconds: consentCache.seconds(for: institutionID))
        let validUntil = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let request = EnableBankingStartAuthorizationRequest(
            access: .init(valid_until: formatter.string(from: validUntil)),
            aspsp: .init(name: aspsp.name, country: aspsp.country),
            state: UUID().uuidString,
            redirect_url: redirectURL?.absoluteString ?? self.redirectURL,
            psu_type: "personal",
            language: Self.bankPageLanguage
        )

        let data = try await api.send(
            path: "/auth",
            method: .post,
            body: request,
            bearerToken: try await jwt()
        )
        let decoded = try JSONDecoder().decode(EnableBankingStartAuthorizationResponse.self, from: data)
        let url = URL(string: decoded.url)
        return (decoded.authorizationId, url)
    }

    func connectionStatus(connectionID: String) async throws -> RemoteConnectionState {
        let data = try await api.send(
            path: "/sessions/\(connectionID)",
            method: .get,
            bearerToken: try await jwt()
        )
        let decoded = try JSONDecoder().decode(EnableBankingSessionResponse.self, from: data)
        return RemoteConnectionState(
            linkedAccountIDs: decoded.accounts,
            authorization: Self.mapSessionStatus(decoded.status),
            consentValidUntil: Self.dateTime(fromString: decoded.access?.validUntil)
        )
    }

    // MARK: - Application (Vorabprüfung)

    /// `GET /application`: Umgebung, Aktivierung und Redirect-URLs der
    /// Anwendung, die zum hinterlegten Schlüssel gehört. Prüft damit
    /// Zugangsdaten und Setup, ohne eine Bank zu berühren.
    func applicationInfo() async throws -> BankApplicationInfo {
        let data = try await api.send(
            path: "/application",
            method: .get,
            bearerToken: try await jwt()
        )
        let decoded = try JSONDecoder().decode(EnableBankingApplicationResponse.self, from: data)
        return BankApplicationInfo(
            name: decoded.name ?? String(localized: "Unbenannte Anwendung"),
            environment: Self.environment(fromString: decoded.environment),
            isActive: decoded.active ?? false,
            redirectURLs: decoded.redirectUrls ?? [],
            countries: decoded.countries ?? []
        )
    }

    static func environment(fromString raw: String?) -> BankApplicationInfo.Environment {
        switch raw?.uppercased() {
        case "PRODUCTION": .production
        case "SANDBOX": .sandbox
        default: .unknown(raw ?? "")
        }
    }

    /// Angefragte Consent-Dauer in Tagen: möglichst `preferredDays`, nie mehr
    /// als das Bank-Maximum; ohne bekanntes Maximum `fallbackDays`.
    static func consentDays(
        maximumSeconds: Int?,
        preferredDays: Int = preferredConsentDays,
        fallbackDays: Int = fallbackConsentDays
    ) -> Int {
        guard let maximumSeconds, maximumSeconds > 0 else { return fallbackDays }
        return max(1, min(preferredDays, maximumSeconds / 86_400))
    }

    /// RFC3339 mit beliebig vielen Nachkommastellen und Zeitzonen-Offset
    /// (Enable Banking: "2026-09-30T12:00:00.000000+00:00").
    static func dateTime(fromString raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        var cleaned = raw
        if let dot = cleaned.firstIndex(of: "."),
           let end = cleaned[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            cleaned.removeSubrange(dot..<end)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: cleaned)
    }

    /// SessionStatus → BankAuthorizationState (Rule 16: provider-spezifische
    /// Statuswerte sickern nicht in die Domain).
    static func mapSessionStatus(_ raw: String) -> BankAuthorizationState {
        switch raw.uppercased() {
        case "AUTHORIZED": .ready
        case "PENDING_AUTHORIZATION", "RETURNED_FROM_BANK": .pending
        case "EXPIRED": .expired
        case "REVOKED", "CANCELLED", "INVALID", "CLOSED": .failed
        default: .unknown(raw)
        }
    }

    // MARK: - Account Data

    func fetchAccountData(accountID: String, dateFrom: Date?) async throws -> RemoteBankAccountData {
        let account = try await fetchAccountDetails(accountID: accountID)
        var queryItems: [URLQueryItem] = []
        if let dateFrom {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            queryItems.append(URLQueryItem(name: "date_from", value: formatter.string(from: dateFrom)))
        }

        let endpoint = "/accounts/\(accountID)/transactions"
        var transactions: [RemoteBankTransaction] = []
        var continuationKey: String?
        var seenKeys: Set<String> = []
        repeat {
            try Task.checkCancellation()
            var pageQuery = queryItems
            if let continuationKey {
                pageQuery.append(URLQueryItem(name: "continuation_key", value: continuationKey))
            }
            let data = try await api.send(
                path: endpoint,
                method: .get,
                queryItems: pageQuery,
                bearerToken: try await jwt()
            )
            let response = try JSONDecoder().decode(EnableBankingTransactionsResponse.self, from: data)
            for dto in response.transactions {
                // Kein Teilimport: fehlerhafte Finanzdaten müssen den Abruf
                // sichtbar scheitern lassen, statt unbemerkt zu fehlen.
                guard let transaction = Self.map(transaction: dto, accountUID: accountID) else {
                    throw BankProviderError.invalidResponse(endpoint: endpoint)
                }
                transactions.append(transaction)
            }
            continuationKey = response.continuationKey
            if let continuationKey {
                guard !continuationKey.isEmpty, seenKeys.insert(continuationKey).inserted else {
                    throw BankProviderError.invalidResponse(endpoint: endpoint)
                }
            }
        } while continuationKey != nil

        return RemoteBankAccountData(account: account, transactions: transactions)
    }

    private func fetchAccountDetails(accountID: String) async throws -> RemoteBankAccount {
        let data = try await api.send(
            path: "/accounts/\(accountID)/details",
            method: .get,
            bearerToken: try await jwt()
        )
        // Spec: Der Endpoint liefert die AccountResource DIREKT (ohne
        // {account: …}-Wrapper).
        let account = try JSONDecoder().decode(EnableBankingAccountResource.self, from: data)
        guard let currency = account.currency, Self.isCurrencyCode(currency) else {
            throw BankProviderError.invalidResponse(endpoint: "/accounts/\(accountID)/details")
        }

        let masked = account.accountId?.identification.flatMap(Self.maskedIBAN)
        return RemoteBankAccount(
            id: accountID,
            // Die uid gilt nur für eine Sitzung; der identification_hash
            // bleibt über Neuanmeldungen gleich und erkennt das Konto wieder.
            providerAccountID: account.identificationHash ?? account.uid ?? accountID,
            ownerName: account.name,
            maskedIBAN: masked,
            currency: CurrencyCode(currency)
        )
    }

    static func maskedIBAN(_ iban: String) -> String {
        let clean = iban.replacingOccurrences(of: " ", with: "")
        guard clean.count > 4 else { return "••••" }
        let last4 = String(clean.suffix(4))
        return "•••• \(last4)"
    }

    // MARK: - Mapping

    static func map(transaction dto: EnableBankingTransaction, accountUID: String) -> RemoteBankTransaction? {
        let rawAmount = dto.transactionAmount.amount
        guard rawAmount.range(of: #"\A[0-9]+(?:\.[0-9]+)?\z"#, options: .regularExpression) != nil,
              let amount = Decimal(string: rawAmount, locale: Locale(identifier: "en_US_POSIX")),
              Self.isCurrencyCode(dto.transactionAmount.currency) else { return nil }
        // CRDT = Gutschrift (positiv), DBIT = Belastung (negativ).
        // Ungültige Pflichtwerte lassen den gesamten Abruf sichtbar scheitern.
        guard let indicator = dto.creditDebitIndicator?.uppercased() else { return nil }
        let signedAmount: Decimal
        switch indicator {
        case "CRDT": signedAmount = amount
        case "DBIT": signedAmount = -amount
        default: return nil
        }

        let status: RemoteBankTransaction.State
        switch dto.status?.uppercased() {
        case "PDNG", "HOLD", "SCHD": status = .pending
        case "BOOK": status = .booked
        default: return nil
        }

        let externalID: String?
        if let entryReference = dto.entryReference, !entryReference.isEmpty {
            // entry_reference ist nur pro Konto eindeutig (#20); das Konto
            // steckt im Dedup-Schlüssel der Pipeline. Die Konto-uid gehört
            // NICHT in die ID: sie wechselt mit jeder Neu-Autorisierung.
            externalID = "eb-\(entryReference)"
        } else {
            externalID = nil
        }

        // Gegenseite: bei Gutschriften der Absender, sonst der Empfänger.
        let counterpartyName = signedAmount > 0 ? dto.debtor?.name : dto.creditor?.name
        let remittance = dto.remittanceInformation?.joined(separator: " ")

        return RemoteBankTransaction(
            externalID: externalID,
            state: status,
            amount: Money(amount: signedAmount, currency: CurrencyCode(dto.transactionAmount.currency)),
            bookingDate: Self.date(fromString: dto.bookingDate),
            valueDate: Self.date(fromString: dto.valueDate ?? dto.transactionDate),
            creditorName: dto.creditor?.name,
            debtorName: dto.debtor?.name,
            remittanceInformation: remittance ?? counterpartyName,
            creditorIBAN: dto.creditorAccount?.iban,
            creditorBIC: dto.creditorAgent?.bicFi,
            debtorIBAN: dto.debtorAccount?.iban,
            debtorBIC: dto.debtorAgent?.bicFi
        )
    }

    static func date(fromString raw: String?) -> Date? {
        GoCardlessDateCodec.parse(raw)
    }

    private static func isCurrencyCode(_ raw: String) -> Bool {
        raw.utf8.count == 3 && raw.utf8.allSatisfy { (65...90).contains($0) }
    }
}

// MARK: - Credentials

struct EnableBankingCredentials: Sendable {
    /// Application ID aus dem Control Panel (JWT-Header `kid`).
    let applicationID: String
    /// Privater Schlüssel der Anwendung (PEM, PKCS#8): Keychain-only.
    let privateKeyPEM: String
}

/// Gemerkte Consent-Maxima je Institut (Sekunden) aus `/aspsps`. Referenz-
/// Semantik, damit der (Struct-)Provider sie über den Verbindungsablauf
/// hinweg behält; die Werte sind keine Secrets.
final class ConsentValidityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: [String: Int] = [:]

    func store(_ value: Int?, for institutionID: String) {
        lock.lock()
        defer { lock.unlock() }
        seconds[institutionID] = value
    }

    func seconds(for institutionID: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return seconds[institutionID]
    }
}

extension EnableBankingBankDataProvider {
    /// Sprache der Bank-Anmeldeseite: Deutsch auf deutschen Macs, sonst Englisch.
    static var bankPageLanguage: String {
        Locale.current.language.languageCode == .german ? "de" : "en"
    }
}
