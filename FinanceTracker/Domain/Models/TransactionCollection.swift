import Foundation

enum TransactionCollectionValidationError: Error, Equatable, Sendable {
    case emptyAccountIDs
    case invalidDateRange
}

struct TransactionCollection: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var systemIconName: String
    let startDate: Date
    let endDateExclusive: Date
    let accountIDs: Set<UUID>
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        systemIconName: String,
        startDate: Date,
        endDateExclusive: Date,
        accountIDs: Set<UUID>,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        guard !accountIDs.isEmpty else {
            throw TransactionCollectionValidationError.emptyAccountIDs
        }
        guard endDateExclusive > startDate else {
            throw TransactionCollectionValidationError.invalidDateRange
        }

        self.id = id
        self.name = name
        self.systemIconName = systemIconName
        self.startDate = startDate
        self.endDateExclusive = endDateExclusive
        self.accountIDs = accountIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                name: container.decode(String.self, forKey: .name),
                systemIconName: container.decode(String.self, forKey: .systemIconName),
                startDate: container.decode(Date.self, forKey: .startDate),
                endDateExclusive: container.decode(Date.self, forKey: .endDateExclusive),
                accountIDs: container.decode(Set<UUID>.self, forKey: .accountIDs),
                createdAt: container.decode(Date.self, forKey: .createdAt),
                updatedAt: container.decode(Date.self, forKey: .updatedAt)
            )
        } catch let error as TransactionCollectionValidationError {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid transaction collection: \(error)"
            ))
        }
    }
}

enum TransactionCollectionOverrideDecision: String, Codable, Sendable, Hashable {
    case include
    case exclude
}

struct TransactionCollectionOverride: Hashable, Codable, Sendable, Identifiable {
    let collectionID: UUID
    let transactionID: UUID
    var decision: TransactionCollectionOverrideDecision
    var createdAt: Date
    var updatedAt: Date

    var id: String { Self.compositeKey(collectionID: collectionID, transactionID: transactionID) }

    init(
        collectionID: UUID,
        transactionID: UUID,
        decision: TransactionCollectionOverrideDecision,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.collectionID = collectionID
        self.transactionID = transactionID
        self.decision = decision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func compositeKey(collectionID: UUID, transactionID: UUID) -> String {
        "\(collectionID.uuidString.lowercased())|\(transactionID.uuidString.lowercased())"
    }
}
