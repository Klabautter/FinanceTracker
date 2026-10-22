import Foundation

struct BankInstitution: Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let bic: String?
    let transactionTotalDays: Int?
    /// Logo der Bank, wenn der Anbieter eins nennt.
    var logoURL: URL? = nil
}

struct RemoteBankAccount: Sendable, Hashable, Identifiable {
    let id: String
    /// Provider-seitige Account-Kennung (z.B. GoCardless Account Resource ID).
    let providerAccountID: String?
    let ownerName: String?
    let maskedIBAN: String?
    let currency: CurrencyCode
}

struct RemoteBankTransaction: Sendable, Hashable {
    enum State: Sendable, Hashable {
        case booked
        case pending
    }

    let externalID: String?
    let state: State
    let amount: Money
    let bookingDate: Date?
    let valueDate: Date?
    let creditorName: String?
    let debtorName: String?
    let remittanceInformation: String?
    var creditorIBAN: String? = nil
    var creditorBIC: String? = nil
    var debtorIBAN: String? = nil
    var debtorBIC: String? = nil

    /// Die andere Seite der Buchung: Bei einer Gutschrift ist der Empfänger
    /// (creditor) der Kontoinhaber selbst: maßgeblich ist dann der Absender
    /// (debtor), bei einer Belastung der Empfänger.
    var counterparty: Counterparty {
        if amount.amount > 0 {
            Counterparty(name: debtorName, iban: debtorIBAN, bic: debtorBIC)
        } else {
            Counterparty(name: creditorName, iban: creditorIBAN, bic: creditorBIC)
        }
    }
}

struct RemoteBankAccountData: Sendable, Hashable {
    let account: RemoteBankAccount
    let transactions: [RemoteBankTransaction]
}

enum BankProviderError: Error, Equatable {
    case missingCredentials
    case invalidResponse(endpoint: String)
    case requestFailed(endpoint: String, status: Int, body: String?)
}

struct RemoteConnectionState: Sendable, Hashable {
    let linkedAccountIDs: [String]
    let authorization: BankAuthorizationState
    /// Tatsächliches Ablaufdatum der Bank-Zustimmung laut Provider (falls
    /// gemeldet). Quelle für `Connection.consentExpiresAt` und damit für die
    /// Ablauf-Warnungen vor einer nötigen Re-Autorisierung.
    var consentValidUntil: Date? = nil
}

/// Provider-neutrale Beschreibung der registrierten API-Anwendung:
/// Grundlage für die Vorabprüfung vor einem echten Banklauf (Umgebung,
/// Aktivierung, Redirect-URL), ohne eine Bank anzufassen.
struct BankApplicationInfo: Sendable, Hashable {
    enum Environment: Sendable, Hashable {
        case production
        case sandbox
        case unknown(String)
    }

    let name: String
    let environment: Environment
    let isActive: Bool
    let redirectURLs: [String]
    let countries: [String]
}

/// Provider, die ihre Anwendung beschreiben können (Enable Banking:
/// `GET /application`). Andere Provider müssen das nicht anbieten.
protocol BankApplicationInfoProviding: Sendable {
    func applicationInfo() async throws -> BankApplicationInfo
}
