import Foundation
@preconcurrency import SwiftData

/// Teil von `PersistenceModelActor` (nach Thema aufgeteilt, Roadmap 7.3).
extension PersistenceModelActor {
    // MARK: - Tag-Relation-Index (WP19)

    /// Schreibt die Join-Rows einer Transaktion neu (idempotent).
    func syncTagJoinRows(transactionID: UUID, tagIDs: [UUID]) {
        let descriptor = FetchDescriptor<SDTransactionTagEntity>(
            predicate: #Predicate { $0.transactionID == transactionID }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        let existingTagIDs = Set(existing.map(\.tagID))
        let target = Set(tagIDs)

        for row in existing where !target.contains(row.tagID) {
            modelContext.delete(row)
        }
        for tagID in target where !existingTagIDs.contains(tagID) {
            modelContext.insert(SDTransactionTagEntity(transactionID: transactionID, tagID: tagID))
        }
    }


    func ensureTagJoinBackfill() throws {
        guard !tagJoinBackfillDone else { return }
        tagJoinBackfillDone = true
        try backfillTagJoinRowsIfNeeded()
    }

    /// Backfill on first use: Bestehende tagIDsJSON-Bestände in Join-Rows
    /// überführen (idempotent, nur Txns, deren Rows fehlen oder abweichen).
    /// Einmal pro Prozess; danach Write-through.
    func backfillTagJoinRowsIfNeeded() throws {
        let taggedTransactionDescriptor = FetchDescriptor<SDTransactionEntity>(
            predicate: #Predicate { $0.tagIDsJSON != nil }
        )
        var candidateIDs = Set(try modelContext.fetch(taggedTransactionDescriptor).map(\.id))
        candidateIDs.formUnion(
            try modelContext.fetch(FetchDescriptor<SDTransactionAnnotationEntity>()).map(\.transactionID)
        )
        candidateIDs.formUnion(
            try modelContext.fetch(FetchDescriptor<SDTransactionTagEntity>()).map(\.transactionID)
        )
        guard !candidateIDs.isEmpty else { return }

        let transactionDescriptor = FetchDescriptor<SDTransactionEntity>(
            predicate: #Predicate { candidateIDs.contains($0.id) }
        )
        let transactions = try modelContext.fetch(transactionDescriptor).map { try $0.toDomain() }
        // Annotation-Tags sind die effektive User-Semantik; bestehende
        // Legacy-Rows und JSON-Facts werden in einem gebündelten Lauf repariert.
        try syncDerivedTransactionIndexes(for: transactions)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// WP19 ANY-Pushdown: Alle Transaction-IDs, die einen der Tags tragen.
    func loadTransactionIDs(tagIDs: Set<UUID>) throws -> Set<UUID> {
        try loadTransactionIDs(tagIDs: tagIDs, mode: .any)
    }

    /// WP9 (§71-72): Tag-ID-Pushdown mit Match-Modus.
    /// - `.any`: Union der Join-Rows.
    /// - `.all`: Intersection auf ID-Ebene (je Tag die ID-Menge, dann
    ///   Schneiden, vollständige Semantik ohne Seiten-Cap).
    func loadTransactionIDs(tagIDs: Set<UUID>, mode: TagMatchMode) throws -> Set<UUID> {
        guard !tagIDs.isEmpty else { return [] }
        switch mode {
        case .any:
            let descriptor = FetchDescriptor<SDTransactionTagEntity>(
                predicate: #Predicate { tagIDs.contains($0.tagID) }
            )
            return Set(try modelContext.fetch(descriptor).map(\.transactionID))
        case .all:
            var intersection: Set<UUID>? = nil
            for tagID in tagIDs {
                let single = Set([tagID])
                let descriptor = FetchDescriptor<SDTransactionTagEntity>(
                    predicate: #Predicate { single.contains($0.tagID) }
                )
                let ids = Set(try modelContext.fetch(descriptor).map(\.transactionID))
                intersection = intersection.map { $0.intersection(ids) } ?? ids
                if intersection?.isEmpty == true { break }
            }
            return intersection ?? []
        }
    }

    /// WP19: Tag löschen → Join-Rows per Pushdown entfernen (§138).
    func deleteTagRows(tagID: UUID) throws {
        let descriptor = FetchDescriptor<SDTransactionTagEntity>(
            predicate: #Predicate { $0.tagID == tagID }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// WP19: Nutzungsanzahl pro Tag per Pushdown (ohne Annotations-Fullload).
    func loadTagUsageCounts() throws -> [UUID: Int] {
        let rows = try modelContext.fetch(FetchDescriptor<SDTransactionTagEntity>())
        var counts: [UUID: Int] = [:]
        for row in rows {
            counts[row.tagID, default: 0] += 1
        }
        return counts
    }

    func loadAllSplitLines() throws -> [TransactionSplitLine] {
        try modelContext.fetch(FetchDescriptor<SDTransactionSplitLineEntity>()).map { try $0.toDomain() }
    }

    func loadSplitLines(parentTransactionID: UUID) throws -> [TransactionSplitLine] {
        let descriptor = FetchDescriptor<SDTransactionSplitLineEntity>(
            predicate: #Predicate { $0.parentTransactionID == parentTransactionID }
        )
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    /// WP14/WP17: Scoped Split-Query, nur Lines der angefragten Parents.
    func loadSplitLines(parentTransactionIDs: Set<UUID>) throws -> [TransactionSplitLine] {
        guard !parentTransactionIDs.isEmpty else { return [] }
        let descriptor = FetchDescriptor<SDTransactionSplitLineEntity>(
            predicate: #Predicate { parentTransactionIDs.contains($0.parentTransactionID) }
        )
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    func upsertSplitLines(_ lines: [TransactionSplitLine]) throws {
        guard !lines.isEmpty else { return }
        let ids = Set(lines.map(\.id))
        let descriptor = FetchDescriptor<SDTransactionSplitLineEntity>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let existingByID = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(descriptor).map { ($0.id, $0) }
        )
        for line in lines {
            if let entity = existingByID[line.id] {
                entity.update(from: line)
            } else {
                modelContext.insert(SDTransactionSplitLineEntity(from: line))
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteSplitLines(parentTransactionID: UUID) throws {
        let descriptor = FetchDescriptor<SDTransactionSplitLineEntity>(
            predicate: #Predicate { $0.parentTransactionID == parentTransactionID }
        )
        for entity in try modelContext.fetch(descriptor) {
            modelContext.delete(entity)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func loadRecurringCommitments() throws -> [RecurringCommitment] {
        try modelContext.fetch(FetchDescriptor<SDRecurringCommitmentEntity>()).map { try $0.toDomain() }
    }

    func loadRecurringCommitment(id: UUID) throws -> RecurringCommitment? {
        let descriptor = FetchDescriptor<SDRecurringCommitmentEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    func upsertRecurringCommitments(_ commitments: [RecurringCommitment]) throws {
        let ids = Set(commitments.map(\.id))
        let descriptor = FetchDescriptor<SDRecurringCommitmentEntity>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let existingByID = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(descriptor).map { ($0.id, $0) }
        )
        for commitment in commitments {
            if let entity = existingByID[commitment.id] {
                entity.update(from: commitment)
            } else {
                modelContext.insert(SDRecurringCommitmentEntity(from: commitment))
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteRecurringCommitment(id: UUID) throws {
        let descriptor = FetchDescriptor<SDRecurringCommitmentEntity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(descriptor) {
            modelContext.delete(entity)
        }
        let occurrenceDescriptor = FetchDescriptor<SDRecurringOccurrenceEntity>(
            predicate: #Predicate { $0.commitmentID == id }
        )
        for entity in try modelContext.fetch(occurrenceDescriptor) {
            modelContext.delete(entity)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func loadRecurringOccurrences(commitmentID: UUID) throws -> [RecurringOccurrence] {
        let descriptor = FetchDescriptor<SDRecurringOccurrenceEntity>(
            predicate: #Predicate { $0.commitmentID == commitmentID }
        )
        return try modelContext.fetch(descriptor).map { occurrence in
            RecurringOccurrence(
                id: occurrence.id,
                commitmentID: occurrence.commitmentID,
                transactionID: occurrence.transactionID,
                createdAt: occurrence.createdAt
            )
        }
    }

    func loadAllRecurringOccurrences() throws -> [RecurringOccurrence] {
        let descriptor = FetchDescriptor<SDRecurringOccurrenceEntity>()
        return try modelContext.fetch(descriptor).map { occurrence in
            RecurringOccurrence(
                id: occurrence.id,
                commitmentID: occurrence.commitmentID,
                transactionID: occurrence.transactionID,
                createdAt: occurrence.createdAt
            )
        }
    }

    func addRecurringOccurrence(_ occurrence: RecurringOccurrence) throws {
        modelContext.insert(SDRecurringOccurrenceEntity(
            id: occurrence.id,
            commitmentID: occurrence.commitmentID,
            transactionID: occurrence.transactionID,
            createdAt: occurrence.createdAt
        ))
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteRecurringOccurrence(id: UUID) throws {
        let descriptor = FetchDescriptor<SDRecurringOccurrenceEntity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(descriptor) {
            modelContext.delete(entity)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }
}
