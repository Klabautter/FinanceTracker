import Foundation
@preconcurrency import SwiftData

/// Teil von `PersistenceModelActor` (nach Thema aufgeteilt, Roadmap 7.3).
extension PersistenceModelActor {
    // MARK: - Transaction Collections (Schema V10)

    func loadTransactionCollections() throws -> [TransactionCollection] {
        try modelContext.fetch(FetchDescriptor<SDTransactionCollectionEntity>())
            .map { try $0.toDomain() }
    }

    func loadTransactionCollection(id: UUID) throws -> TransactionCollection? {
        var descriptor = FetchDescriptor<SDTransactionCollectionEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map { try $0.toDomain() }
    }

    func upsertTransactionCollections(_ collections: [TransactionCollection]) throws {
        guard !collections.isEmpty else { return }
        let ids = Set(collections.map(\.id))
        let descriptor = FetchDescriptor<SDTransactionCollectionEntity>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let existing = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(descriptor).map { ($0.id, $0) }
        )
        for collection in collections {
            if let row = existing[collection.id] {
                try row.update(from: collection)
            } else {
                modelContext.insert(try SDTransactionCollectionEntity(from: collection))
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteTransactionCollection(id: UUID) throws {
        try deleteTransactionCollectionOverrides(collectionID: id)
        let descriptor = FetchDescriptor<SDTransactionCollectionEntity>(
            predicate: #Predicate { $0.id == id }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteAllTransactionCollections() throws {
        try modelContext.delete(model: SDTransactionCollectionOverrideEntity.self)
        try modelContext.delete(model: SDTransactionCollectionEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func loadTransactionCollectionOverrides(collectionID: UUID) throws -> [TransactionCollectionOverride] {
        let descriptor = FetchDescriptor<SDTransactionCollectionOverrideEntity>(
            predicate: #Predicate { $0.collectionID == collectionID }
        )
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    func loadAllTransactionCollectionOverrides() throws -> [TransactionCollectionOverride] {
        try modelContext.fetch(FetchDescriptor<SDTransactionCollectionOverrideEntity>())
            .map { try $0.toDomain() }
    }

    func loadTransactionCollectionOverride(
        collectionID: UUID,
        transactionID: UUID
    ) throws -> TransactionCollectionOverride? {
        let key = TransactionCollectionOverride.compositeKey(
            collectionID: collectionID,
            transactionID: transactionID
        )
        var descriptor = FetchDescriptor<SDTransactionCollectionOverrideEntity>(
            predicate: #Predicate { $0.compositeKey == key }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map { try $0.toDomain() }
    }

    func upsertTransactionCollectionOverrides(_ overrides: [TransactionCollectionOverride]) throws {
        guard !overrides.isEmpty else { return }
        let keys = Set(overrides.map(\.id))
        let descriptor = FetchDescriptor<SDTransactionCollectionOverrideEntity>(
            predicate: #Predicate { keys.contains($0.compositeKey) }
        )
        let existing = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(descriptor).map { ($0.compositeKey, $0) }
        )
        for override in overrides {
            if let row = existing[override.id] {
                row.update(from: override)
            } else {
                modelContext.insert(SDTransactionCollectionOverrideEntity(from: override))
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteTransactionCollectionOverride(collectionID: UUID, transactionID: UUID) throws {
        let key = TransactionCollectionOverride.compositeKey(
            collectionID: collectionID,
            transactionID: transactionID
        )
        let descriptor = FetchDescriptor<SDTransactionCollectionOverrideEntity>(
            predicate: #Predicate { $0.compositeKey == key }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteTransactionCollectionOverrides(collectionID: UUID) throws {
        let descriptor = FetchDescriptor<SDTransactionCollectionOverrideEntity>(
            predicate: #Predicate { $0.collectionID == collectionID }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteAllTransactionCollectionOverrides() throws {
        try modelContext.delete(model: SDTransactionCollectionOverrideEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    // MARK: - Shared Expense Shares (Schema V12, #27/#11)

    func loadAllSharedExpenseShares() throws -> [SharedExpenseShare] {
        try modelContext.fetch(FetchDescriptor<SDSharedExpenseShareEntity>()).map { try $0.toDomain() }
    }

    func loadSharedExpenseShares(transactionID: UUID) throws -> [SharedExpenseShare] {
        let descriptor = FetchDescriptor<SDSharedExpenseShareEntity>(
            predicate: #Predicate { $0.transactionID == transactionID }
        )
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    /// Scoped Query für mehrere Transaktionen (kein Full-Load).
    func loadSharedExpenseShares(transactionIDs: Set<UUID>) throws -> [SharedExpenseShare] {
        guard !transactionIDs.isEmpty else { return [] }
        let descriptor = FetchDescriptor<SDSharedExpenseShareEntity>(
            predicate: #Predicate { transactionIDs.contains($0.transactionID) }
        )
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    func loadSharedExpenseShare(id: UUID) throws -> SharedExpenseShare? {
        var descriptor = FetchDescriptor<SDSharedExpenseShareEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map { try $0.toDomain() }
    }

    func upsertSharedExpenseShares(_ shares: [SharedExpenseShare]) throws {
        guard !shares.isEmpty else { return }
        let ids = Set(shares.map(\.id))
        let descriptor = FetchDescriptor<SDSharedExpenseShareEntity>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let existingByID = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(descriptor).map { ($0.id, $0) }
        )
        for share in shares {
            if let entity = existingByID[share.id] {
                entity.update(from: share)
            } else {
                modelContext.insert(SDSharedExpenseShareEntity(from: share))
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteSharedExpenseShare(id: UUID) throws {
        let descriptor = FetchDescriptor<SDSharedExpenseShareEntity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(descriptor) {
            modelContext.delete(entity)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteSharedExpenseShares(transactionID: UUID) throws {
        let descriptor = FetchDescriptor<SDSharedExpenseShareEntity>(
            predicate: #Predicate { $0.transactionID == transactionID }
        )
        for entity in try modelContext.fetch(descriptor) {
            modelContext.delete(entity)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteAllSharedExpenseShares() throws {
        try modelContext.delete(model: SDSharedExpenseShareEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// Cascade-Helfer für Transaktions-Löschpfade (kein eigener Save:
    /// der aufrufende Schreibpfad übernimmt Save/Rollback).
    func deleteSharedExpenseShareRows(transactionIDs: Set<UUID>) throws {
        guard !transactionIDs.isEmpty else { return }
        let descriptor = FetchDescriptor<SDSharedExpenseShareEntity>(
            predicate: #Predicate { transactionIDs.contains($0.transactionID) }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
    }
}
