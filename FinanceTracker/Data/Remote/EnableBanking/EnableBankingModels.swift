import Foundation

/// Enable Banking API (https://api.enablebanking.com, OpenAPI-Spec
/// enablebanking-api.yaml). Nur die Felder, die die App braucht: DTOs
/// sind tolerante Decodables (optionale Felder), damit fremde ASPSP-
/// Varianten nicht hart crashen (Rule 16: Normalisierung im Provider).
enum EnableBankingAPI {
    /// Sandbox und Production teilen dieselbe API-URL; die Umgebung hängt
    /// an der registrierten Anwendung (Control Panel).
    static let baseURL = URL(string: "https://api.enablebanking.com")!
}

// MARK: - ASPSPs

struct EnableBankingASPSP: Decodable, Sendable {
    let name: String
    let country: String
    let psuTypes: [String]?
    let maximumConsentValidity: Int?
    let logo: String?

    enum CodingKeys: String, CodingKey {
        case name
        case country
        case psuTypes = "psu_types"
        case maximumConsentValidity = "maximum_consent_validity"
        case logo
    }
}

struct EnableBankingASPSResponse: Decodable, Sendable {
    let aspsps: [EnableBankingASPSP]
}

// MARK: - Authorization

struct EnableBankingStartAuthorizationRequest: Encodable, Sendable {
    struct Access: Encodable, Sendable {
        let valid_until: String
    }

    struct ASPSP: Encodable, Sendable {
        let name: String
        let country: String
    }

    let access: Access
    let aspsp: ASPSP
    let state: String
    let redirect_url: String
    let psu_type: String
    let language: String
}

struct EnableBankingStartAuthorizationResponse: Decodable, Sendable {
    let url: String
    let authorizationId: String

    enum CodingKeys: String, CodingKey {
        case url
        case authorizationId = "authorization_id"
    }
}

// MARK: - Session

struct EnableBankingSessionAccount: Decodable, Sendable {
    let uid: String?
    let currency: String?
    let name: String?
    /// Primärer Konto-Identifier (z. B. IBAN) als Scheme/Value-Paar.
    let accountId: EnableBankingAccountIdentification?

    enum CodingKeys: String, CodingKey {
        case uid
        case currency
        case name
        case accountId = "account_id"
    }
}

struct EnableBankingAccountIdentification: Decodable, Sendable {
    let schemeName: String?
    let identification: String?

    enum CodingKeys: String, CodingKey {
        case schemeName = "scheme_name"
        case identification
    }
}

struct EnableBankingAuthorizeSessionResponse: Decodable, Sendable {
    let sessionId: String
    let accounts: [EnableBankingSessionAccount]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case accounts
    }
}

struct EnableBankingAccess: Decodable, Sendable {
    /// RFC3339, z. B. "2026-09-30T12:00:00.000000+00:00".
    let validUntil: String?

    enum CodingKeys: String, CodingKey {
        case validUntil = "valid_until"
    }
}

struct EnableBankingSessionResponse: Decodable, Sendable {
    let status: String
    /// Account-UIDs (Liste von UUID-Strings): Quelle für Sync-Fetches.
    let accounts: [String]
    /// Accounts mit Details (currency/name): SessionAccount-Payload.
    let accountsData: [EnableBankingSessionAccount]?
    /// Zustimmungsfenster der Session (tatsächliche Gültigkeit).
    let access: EnableBankingAccess?

    enum CodingKeys: String, CodingKey {
        case status
        case accounts
        case accountsData = "accounts_data"
        case access
    }
}

// MARK: - Application

/// GET /application: „Get application associated with provided JWT key ID".
struct EnableBankingApplicationResponse: Decodable, Sendable {
    let name: String?
    /// "PRODUCTION" / "SANDBOX".
    let environment: String?
    let redirectUrls: [String]?
    let active: Bool?
    let countries: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case environment
        case redirectUrls = "redirect_urls"
        case active
        case countries
    }
}

// MARK: - Account Details

/// GET /accounts/{id}/details liefert die Resource DIREKT (Spec, 200-Response
/// = AccountResource ohne Wrapper).
struct EnableBankingAccountResource: Decodable, Sendable {
    let uid: String?
    let currency: String?
    let name: String?
    let accountId: EnableBankingAccountIdentification?
    let identificationHash: String?

    enum CodingKeys: String, CodingKey {
        case uid
        case currency
        case name
        case accountId = "account_id"
        case identificationHash = "identification_hash"
    }
}

// MARK: - Balances

struct EnableBankingBalancesResponse: Decodable, Sendable {
    let balances: [EnableBankingBalance]
}

struct EnableBankingBalance: Decodable, Sendable {
    /// "interimAvailable" / "closingBooked" etc.
    let balanceType: String?
    let balanceAmount: EnableBankingAmount

    enum CodingKeys: String, CodingKey {
        case balanceType = "balance_type"
        case balanceAmount = "balance_amount"
    }
}

// MARK: - Transactions

struct EnableBankingAmount: Decodable, Sendable {
    let amount: String
    let currency: String
}

struct EnableBankingParty: Decodable, Sendable {
    let name: String?
}

struct EnableBankingAccountReference: Decodable, Sendable {
    let iban: String?
}

struct EnableBankingAgent: Decodable, Sendable {
    let bicFi: String?

    enum CodingKeys: String, CodingKey {
        case bicFi = "bic_fi"
    }
}

struct EnableBankingTransaction: Decodable, Sendable {
    let entryReference: String?
    let transactionAmount: EnableBankingAmount
    let creditDebitIndicator: String?
    /// BOOK / PDNG / CNCL / HOLD / OTHR / RJCT / SCHD
    let status: String?
    let bookingDate: String?
    let valueDate: String?
    let transactionDate: String?
    let creditor: EnableBankingParty?
    let debtor: EnableBankingParty?
    var creditorAccount: EnableBankingAccountReference? = nil
    var debtorAccount: EnableBankingAccountReference? = nil
    var creditorAgent: EnableBankingAgent? = nil
    var debtorAgent: EnableBankingAgent? = nil
    let remittanceInformation: [String]?
    let merchantCategoryCode: String?

    enum CodingKeys: String, CodingKey {
        case entryReference = "entry_reference"
        case transactionAmount = "transaction_amount"
        case creditDebitIndicator = "credit_debit_indicator"
        case status
        case bookingDate = "booking_date"
        case valueDate = "value_date"
        case transactionDate = "transaction_date"
        case creditor
        case debtor
        case creditorAccount = "creditor_account"
        case debtorAccount = "debtor_account"
        case creditorAgent = "creditor_agent"
        case debtorAgent = "debtor_agent"
        case remittanceInformation = "remittance_information"
        case merchantCategoryCode = "merchant_category_code"
    }
}

struct EnableBankingTransactionsResponse: Decodable, Sendable {
    let transactions: [EnableBankingTransaction]
    let continuationKey: String?

    enum CodingKeys: String, CodingKey {
        case transactions
        case continuationKey = "continuation_key"
    }
}
