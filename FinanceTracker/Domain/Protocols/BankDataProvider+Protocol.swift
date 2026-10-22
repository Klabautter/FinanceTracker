import Foundation

enum BankAuthorizationState: Sendable, Hashable {
    case pending
    case ready
    case failed
    case expired
    case unknown(String)
}

protocol BankDataProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }

    func institutions(country: String) async throws -> [BankInstitution]
    func createConnection(institutionID: String, redirectURL: URL?) async throws -> (connectionID: String, authorizationURL: URL?)
    func connectionStatus(connectionID: String) async throws -> RemoteConnectionState
    func fetchAccountData(accountID: String, dateFrom: Date?) async throws -> RemoteBankAccountData

    /// Redirect-Code-Flow (z. B. Enable Banking `POST /sessions`): tauscht
    /// den `code` aus der Redirect-URL gegen eine provider-seitige Session-
    /// ID. Provider ohne Code-Flow werfen einen kontrollierten Fehler.
    func authorizeSession(code: String) async throws -> String

    /// Name der Bank zu einer gespeicherten Institutions-ID, ohne
    /// Netzwerkzugriff; `nil`, wenn die ID ihn nicht hergibt.
    func institutionDisplayName(forInstitutionID institutionID: String) -> String?
}

extension BankDataProvider {
    func institutionDisplayName(forInstitutionID institutionID: String) -> String? { nil }
}
