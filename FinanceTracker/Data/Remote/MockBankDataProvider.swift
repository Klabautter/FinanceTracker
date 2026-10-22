import Foundation

final class MockBankDataProvider: BankDataProvider, @unchecked Sendable {
    var identifier: String = ConnectionProvider.gocardless.rawValue
    var displayName: String = "Mock Bank"

    var stubbedInstitutions: [BankInstitution] = [
        BankInstitution(id: "SANDBOXFINANCE_SFIN000033", name: "Sandbox Finance", bic: "SFINDE33XXX", transactionTotalDays: 90)
    ]

    var stubbedLinkedAccountIDs: [String] = ["acc-1"]
    var stubbedAuthorization: BankAuthorizationState = .ready
    var stubbedRemoteAccounts: [RemoteBankAccount] = [RemoteBankAccount(
        id: "acc-1",
        providerAccountID: "acc-1",
        ownerName: "Test User",
        maskedIBAN: "•••• 4821",
        currency: .eur
    )]
    private(set) var fetchAccountDataCallCount = 0

    var stubbedTransactions: [RemoteBankTransaction] = []

    func setAuthorization(_ state: BankAuthorizationState) { stubbedAuthorization = state }

    func institutions(country: String) async throws -> [BankInstitution] {
        stubbedInstitutions
    }

    func createConnection(institutionID: String, redirectURL: URL?) async throws -> (connectionID: String, authorizationURL: URL?) {
        ("mock-requisition-1", URL(string: "https://ob.mock/auth"))
    }

    func connectionStatus(connectionID: String) async throws -> RemoteConnectionState {
        RemoteConnectionState(
            linkedAccountIDs: stubbedLinkedAccountIDs,
            authorization: stubbedAuthorization
        )
    }

    func authorizeSession(code: String) async throws -> String {
        "mock-session-1"
    }

    /// Zuletzt angefragtes Startdatum (für Tests des Abrufzeitraums).
    private(set) var lastRequestedDateFrom: Date??

    func fetchAccountData(accountID: String, dateFrom: Date?) async throws -> RemoteBankAccountData {
        lastRequestedDateFrom = .some(dateFrom)
        fetchAccountDataCallCount += 1
        let account = stubbedRemoteAccounts.first { $0.id == accountID }
            ?? RemoteBankAccount(
                id: accountID,
                providerAccountID: accountID,
                ownerName: nil,
                maskedIBAN: nil,
                currency: .eur
            )
        return RemoteBankAccountData(account: account, transactions: stubbedTransactions)
    }

    static func demoInstitution() -> BankInstitution {
        BankInstitution(id: "DEMO_BANK_01", name: "Demo-Bank", bic: nil, transactionTotalDays: 90)
    }

    static func demoLinkedAccount() -> RemoteBankAccount {
        RemoteBankAccount(
            id: "demo-acc-1",
            providerAccountID: "demo-acc-1",
            ownerName: "Demo Nutzer",
            maskedIBAN: "•••• 0001",
            currency: .eur
        )
    }

    static func demoTransactions(now: Date = Date()) -> [RemoteBankTransaction] {
        let calendar = Calendar.current
        func day(_ offset: Int) -> Date? { calendar.date(byAdding: .day, value: offset, to: now) }

        return [
            RemoteBankTransaction(
                externalID: "demo-T1",
                state: .booked,
                amount: Money(amount: Decimal(string: "-43.27")!, currency: .eur),
                bookingDate: day(-20),
                valueDate: day(-20),
                creditorName: "REWE MARKT 1234",
                debtorName: nil,
                remittanceInformation: "Wocheneinkauf"
            ),
            RemoteBankTransaction(
                externalID: "demo-T2",
                state: .booked,
                amount: Money(amount: Decimal(string: "-10.99")!, currency: .eur),
                bookingDate: day(-6),
                valueDate: day(-6),
                creditorName: "SPOTIFY AB",
                debtorName: nil,
                remittanceInformation: "Premium Abo"
            ),
            RemoteBankTransaction(
                externalID: "demo-T3",
                state: .booked,
                amount: Money(amount: Decimal(string: "2850.00")!, currency: .eur),
                bookingDate: day(-5),
                valueDate: day(-5),
                creditorName: nil,
                debtorName: "Acme GmbH",
                remittanceInformation: "Gehalt August"
            ),
            RemoteBankTransaction(
                externalID: "demo-T4",
                state: .pending,
                amount: Money(amount: Decimal(string: "-18.30")!, currency: .eur),
                bookingDate: nil,
                valueDate: day(0),
                creditorName: "MCDONALDS 155",
                debtorName: nil,
                remittanceInformation: "Card Purchase"
            )
        ]
    }

}
