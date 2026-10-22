import Foundation

enum GoCardlessAPI {
    static let baseURL = URL(string: "https://bankaccountdata.gocardless.com/api/v2")!
}

struct GoCardlessCredentials: Sendable, Codable {
    let secretID: String
    let secretKey: String
}

struct GoCardlessTokenResponse: Decodable {
    let access: String
    let accessExpires: Date

    enum CodingKeys: String, CodingKey {
        case access
        case accessExpires = "access_expires"
    }
}

struct GoCardlessInstitutionDTO: Decodable {
    let id: String
    let name: String
    let bic: String?
    let maxAccessValidFor: String?

    var summary: BankInstitution {
        BankInstitution(
            id: id,
            name: name,
            bic: bic,
            transactionTotalDays: maxAccessValidFor.flatMap { Int($0.replacingOccurrences(of: "d", with: "")) }
        )
    }
}

struct GoCardlessRequisitionDTO: Decodable {
    let id: String
    let status: String
    let accounts: [String]
    let link: URL?

    enum CodingKeys: String, CodingKey {
        case id, status, accounts, link
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        status = (try? container.decode(String.self, forKey: .status)) ?? ""
        accounts = (try? container.decode([String].self, forKey: .accounts)) ?? []
        link = try? container.decode(URL.self, forKey: .link)
    }
}

struct GoCardlessAccountDetailsDTO: Decodable {
    struct Account: Decodable {
        let resourceId: String?
        let ownerName: String?
        let iban: String?
        let currency: String?
    }

    let account: Account
}

struct GoCardlessBalanceDTO: Decodable {
    struct Balance: Decodable {
        struct BalanceAmount: Codable {
            let amount: String
            let currency: String
        }

        let balanceAmount: BalanceAmount
        let balanceType: String
    }

    let balances: [Balance]
}

struct GoCardlessTransactionsResponseDTO: Decodable {
    struct Transaction: Decodable {
        let transactionId: String?
        let entryReference: String?
        let bookingDate: String?
        let valueDate: String?
        let transactionAmount: GoCardlessBalanceDTO.Balance.BalanceAmount
        let creditorName: String?
        let debtorName: String?
        var creditorAccount: AccountReference? = nil
        var debtorAccount: AccountReference? = nil
        let remittanceInformationUnstructured: String?

        struct AccountReference: Decodable {
            let iban: String?
        }

        var state: RemoteBankTransaction.State {
            // In the /transactions endpoint booked and pending arrive in
            // separate arrays; the state is assigned by the parser.
            .booked
        }
    }

    struct BookedPending: Decodable {
        let booked: [Transaction]?
        let pending: [Transaction]?
    }

    let transactions: BookedPending
}
