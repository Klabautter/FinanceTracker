import Foundation

final class DetailCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

struct GoCardlessBankDataProvider: BankDataProvider {
    let identifier: String = ConnectionProvider.gocardless.rawValue
    let displayName: String = "GoCardless Bank Account Data"

    private var api: APIClient { APIClient(baseURL: GoCardlessAPI.baseURL, transport: transport) }
    private let transport: any HTTPTransport
    private let credentialsProvider: @Sendable () async throws -> GoCardlessCredentials
    private let now: @Sendable () -> Date

    private let tokenStore = GoCardlessAccessTokenStore()

    init(
        transport: any HTTPTransport = URLSessionTransport(),
        credentialsProvider: @escaping @Sendable () async throws -> GoCardlessCredentials,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.credentialsProvider = credentialsProvider
        self.now = now
    }

    // MARK: - Auth

    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let cached = await tokenStore.validToken(now: now()) {
            return cached
        }

        let credentials = try await credentialsProvider()
        struct TokenRequest: Encodable {
            let secret_id: String
            let secret_key: String
        }

        let data = try await api.send(
            path: "/token/new/",
            method: .post,
            body: TokenRequest(secret_id: credentials.secretID, secret_key: credentials.secretKey)
        )

        let decoded = try JSONDecoder.goCardless.decode(GoCardlessTokenResponse.self, from: data)
        await tokenStore.store(token: .init(value: decoded.access, expiresAt: decoded.accessExpires))
        return decoded.access
    }

    private func authenticatedGet(path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        let token = try await accessToken()

        do {
            return try await api.send(
                path: path,
                method: .get,
                queryItems: queryItems,
                bearerToken: token
            )
        } catch let error as BankProviderError {
            guard case .requestFailed(_, 401, _) = error else { throw error }

            // Genau ein Retry mit frischem Token.
            await tokenStore.invalidate()
            let freshToken = try await accessToken(forceRefresh: true)
            return try await api.send(
                path: path,
                method: .get,
                queryItems: queryItems,
                bearerToken: freshToken
            )
        }
    }

    // MARK: - BankDataProvider

    func institutions(country: String) async throws -> [BankInstitution] {
        let data = try await authenticatedGet(
            path: "/institutions/",
            queryItems: [URLQueryItem(name: "country", value: country)]
        )
        let decoded = try JSONDecoder.goCardless.decode([GoCardlessInstitutionDTO].self, from: data)
        return decoded.map(\.summary).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func createConnection(institutionID: String, redirectURL: URL?) async throws -> (connectionID: String, authorizationURL: URL?) {
        struct RequisitionRequest: Encodable {
            let redirect: String?
            let institution_id: String
            let user_language: String
            let reference: String
        }

        let reference = UUID().uuidString
        let data = try await api.send(
            path: "/requisitions/",
            method: .post,
            body: RequisitionRequest(
                redirect: redirectURL?.absoluteString,
                institution_id: institutionID,
                user_language: Self.bankPageLanguage,
                reference: reference
            ),
            bearerToken: try await accessToken()
        )

        let requisition = try JSONDecoder.goCardless.decode(GoCardlessRequisitionDTO.self, from: data)
        return (requisition.id, requisition.link)
    }

    /// GoCardless nutzt Requisitions-Status statt Redirect-Codes.
    func authorizeSession(code: String) async throws -> String {
        throw BankProviderError.invalidResponse(endpoint: "code-exchange")
    }

    func connectionStatus(connectionID: String) async throws -> RemoteConnectionState {
        let data = try await authenticatedGet(path: "/requisitions/\(connectionID)/")
        let requisition = try JSONDecoder.goCardless.decode(GoCardlessRequisitionDTO.self, from: data)
        return RemoteConnectionState(
            linkedAccountIDs: requisition.accounts,
            authorization: Self.mapAuthorization(requisition.status)
        )
    }

    static func mapAuthorization(_ raw: String) -> BankAuthorizationState {
        switch raw.uppercased() {
        case "LN", "LINKED": .ready
        case "CR", "GC": .pending
        case "EX": .expired
        case "RJ", "DL": .failed
        default: .unknown(raw)
        }
    }

    func fetchAccountData(accountID: String, dateFrom: Date?) async throws -> RemoteBankAccountData {
        let account = try await fetchAccountDetails(accountID: accountID)

        let path = "/accounts/\(accountID)/transactions/"
        var queryItems: [URLQueryItem] = []
        if let dateFrom {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            queryItems.append(URLQueryItem(name: "date_from", value: formatter.string(from: dateFrom)))
        }

        let data = try await authenticatedGet(path: path, queryItems: queryItems)
        let response = try JSONDecoder.goCardless.decode(GoCardlessTransactionsResponseDTO.self, from: data)

        let booked = (response.transactions.booked ?? []).compactMap {
            Self.map(transaction: $0, state: .booked)
        }
        let pending = (response.transactions.pending ?? []).compactMap {
            Self.map(transaction: $0, state: .pending)
        }

        return RemoteBankAccountData(
            account: account,
            transactions: booked + pending
        )
    }

    private let detailCounter = DetailCallCounter()

    var detailCallCount: Int { detailCounter.value }

    private func fetchAccountDetails(accountID: String) async throws -> RemoteBankAccount {
        detailCounter.increment()

        let data = try await authenticatedGet(path: "/accounts/\(accountID)/")
        let dto = try JSONDecoder.goCardless.decode(GoCardlessAccountDetailsDTO.self, from: data)

        return RemoteBankAccount(
            id: accountID,
            providerAccountID: dto.account.resourceId ?? accountID,
            ownerName: dto.account.ownerName,
            maskedIBAN: dto.account.iban.flatMap { Self.maskedIBAN($0) },
            currency: dto.account.currency.map(CurrencyCode.init) ?? .eur
        )
    }

    static func maskedIBAN(_ iban: String) -> String {
        let clean = iban.replacingOccurrences(of: " ", with: "")
        guard clean.count > 4 else { return "••••" }
        let last4 = String(clean.suffix(4))
        return "•••• \(last4)"
    }

    static func mapTransactionForTesting(_ dto: GoCardlessTransactionsResponseDTO.Transaction, state: RemoteBankTransaction.State) -> RemoteBankTransaction? {
        map(transaction: dto, state: state)
    }

    private static func map(transaction dto: GoCardlessTransactionsResponseDTO.Transaction, state: RemoteBankTransaction.State) -> RemoteBankTransaction? {
        guard let amountDecimal = Decimal(string: dto.transactionAmount.amount) else { return nil }

        return RemoteBankTransaction(
            externalID: dto.transactionId ?? dto.entryReference ?? UUID().uuidString,
            state: state,
            amount: Money(amount: amountDecimal, currency: CurrencyCode(dto.transactionAmount.currency)),
            bookingDate: Self.date(fromString: dto.bookingDate),
            valueDate: Self.date(fromString: dto.valueDate),
            creditorName: dto.creditorName,
            debtorName: dto.debtorName,
            remittanceInformation: dto.remittanceInformationUnstructured,
            creditorIBAN: dto.creditorAccount?.iban,
            debtorIBAN: dto.debtorAccount?.iban
        )
    }

    static func date(fromString raw: String?) -> Date? {
        GoCardlessDateCodec.parse(raw)
    }
}

extension JSONDecoder {
    static let goCardless: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)

            for format in ["yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"] {
                let formatter = DateFormatter()
                formatter.dateFormat = format
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "UTC")
                if let date = formatter.date(from: raw) {
                    return date
                }
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unbekanntes Datumsformat: \(raw)")
        }
        return decoder
    }()
}

extension GoCardlessBankDataProvider {
    /// Sprache der Bank-Anmeldeseite: Deutsch auf deutschen Macs, sonst Englisch.
    static var bankPageLanguage: String {
        Locale.current.language.languageCode == .german ? "de" : "en"
    }
}
