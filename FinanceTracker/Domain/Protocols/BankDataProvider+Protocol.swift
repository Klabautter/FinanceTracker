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
    /// Wie `createConnection(institutionID:redirectURL:)`, aber mit einem
    /// vom Aufrufer gewählten `state`. Provider mit Redirect-Code-Flow
    /// geben ihn an die Bank weiter; die Rückkehr-Adresse muss denselben
    /// Wert tragen, sonst gehört sie nicht zu dieser Anmeldung.
    func createConnection(institutionID: String, redirectURL: URL?, state: String) async throws -> (connectionID: String, authorizationURL: URL?)
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
    /// Provider ohne Redirect-Code-Flow brauchen den `state` nicht.
    func createConnection(institutionID: String, redirectURL: URL?, state: String) async throws -> (connectionID: String, authorizationURL: URL?) {
        try await createConnection(institutionID: institutionID, redirectURL: redirectURL)
    }
    func institutionDisplayName(forInstitutionID institutionID: String) -> String? { nil }
}
