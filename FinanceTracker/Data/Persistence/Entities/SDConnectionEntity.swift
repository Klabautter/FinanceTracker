import Foundation
import SwiftData

@Model
final class SDConnectionEntity {
    @Attribute(.unique) var id: UUID
    var providerRaw: String
    var providerConnectionID: String?
    var institutionID: String?
    var institutionName: String?
    var statusRaw: String
    var linkedAccountIDs: [String]
    var consentExpiresAt: Date?
    var lastSuccessfulSyncAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        providerRaw: String,
        providerConnectionID: String?,
        institutionID: String?,
        institutionName: String?,
        statusRaw: String,
        linkedAccountIDs: [String],
        consentExpiresAt: Date?,
        lastSuccessfulSyncAt: Date?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.providerRaw = providerRaw
        self.providerConnectionID = providerConnectionID
        self.institutionID = institutionID
        self.institutionName = institutionName
        self.statusRaw = statusRaw
        self.linkedAccountIDs = linkedAccountIDs
        self.consentExpiresAt = consentExpiresAt
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension SDConnectionEntity {
    convenience init(from connection: Connection) {
        self.init(
            id: connection.id,
            providerRaw: connection.provider.rawValue,
            providerConnectionID: connection.providerConnectionID,
            institutionID: connection.institutionID,
            institutionName: connection.institutionName,
            statusRaw: connection.status.rawValue,
            linkedAccountIDs: [],
            consentExpiresAt: connection.consentExpiresAt,
            lastSuccessfulSyncAt: connection.lastSuccessfulSyncAt,
            createdAt: connection.createdAt,
            updatedAt: connection.updatedAt
        )
    }

    func update(from connection: Connection) {
        providerRaw = connection.provider.rawValue
        providerConnectionID = connection.providerConnectionID
        institutionID = connection.institutionID
        institutionName = connection.institutionName
        statusRaw = connection.status.rawValue
        consentExpiresAt = connection.consentExpiresAt
        lastSuccessfulSyncAt = connection.lastSuccessfulSyncAt
        updatedAt = connection.updatedAt
    }

    func toDomain() -> Connection {
        Connection(
            id: id,
            userID: UUID(),
            provider: ConnectionProvider(rawValue: providerRaw) ?? .gocardless,
            providerConnectionID: providerConnectionID,
            institutionID: institutionID,
            status: ConnectionStatus(rawValue: statusRaw) ?? .active,
            consentExpiresAt: consentExpiresAt,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            institutionName: institutionName
        )
    }
}
