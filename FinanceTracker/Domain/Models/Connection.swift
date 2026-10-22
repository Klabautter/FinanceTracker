import Foundation

enum ConnectionProvider: String, Codable, Sendable, CaseIterable {
    case local
    case gocardless
    case enablebanking
    case tink
    case future
    case mock

    var displayName: String {
        switch self {
        case .local: String(localized: "Lokal")
        case .gocardless: "GoCardless"
        case .enablebanking: "Enable Banking"
        case .tink: "Tink"
        case .future: String(localized: "Zukünftig")
        case .mock: String(localized: "Demo-Bank")
        }
    }
}

enum ConnectionStatus: String, Codable, Sendable {
    case pendingAuthorization
    case active
    case expired
    case revoked
    case disconnected
}

struct Connection: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var userID: UUID
    var provider: ConnectionProvider
    var providerConnectionID: String?
    var institutionID: String?
    var status: ConnectionStatus
    var consentExpiresAt: Date?
    var lastSuccessfulSyncAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// Name der Bank, wie ihn der Anbieter nennt (z. B. „VR Bank …“).
    var institutionName: String? = nil

    /// Anzeigename: die Bank, sonst der Anbieter.
    var displayName: String {
        if let institutionName, !institutionName.isEmpty { return institutionName }
        return provider.displayName
    }
}
