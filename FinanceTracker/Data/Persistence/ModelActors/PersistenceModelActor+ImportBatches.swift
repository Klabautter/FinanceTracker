import Foundation
@preconcurrency import SwiftData

/// Teil von `PersistenceModelActor` (nach Thema aufgeteilt, Roadmap 7.3).
extension PersistenceModelActor {
    func commitImportBatch(
        batch: ImportBatch,
        inserts: [Transaction],
        updates: [Transaction]
    ) throws {
        do {
            let allByID = (inserts + updates).reduce(into: [UUID: Transaction]()) { result, transaction in
                result[transaction.id] = transaction
            }
            let all = Array(allByID.values)
            if !all.isEmpty {
                let ids = Set(allByID.keys)
                let descriptor = FetchDescriptor<SDTransactionEntity>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                let existingRows = try modelContext.fetch(descriptor)
                let existingByID = Dictionary(uniqueKeysWithValues: existingRows.map { ($0.id, $0) })

                for transaction in all {
                    if let entity = existingByID[transaction.id] {
                        entity.update(from: transaction)
                    } else {
                        modelContext.insert(SDTransactionEntity(from: transaction))
                    }
                }

                try syncDerivedTransactionIndexes(for: all)
            }

            let batchID = batch.id
            let batchDescriptor = FetchDescriptor<SDImportBatchEntity>(
                predicate: #Predicate { $0.id == batchID }
            )
            if let existingBatch = try modelContext.fetch(batchDescriptor).first {
                existingBatch.update(from: batch)
            } else {
                modelContext.insert(SDImportBatchEntity(from: batch))
            }

            // Transaktionen, Suchindex, Tag-Join-Index und ImportBatch sind
            // eine gemeinsame persistente Commit-Einheit.
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func rollbackImportBatch(id: UUID) throws {
        do {
            let batchDescriptor = FetchDescriptor<SDImportBatchEntity>(
                predicate: #Predicate { $0.id == id }
            )
            guard let batchEntity = try modelContext.fetch(batchDescriptor).first else { return }

            // Ohne lesbare Mutationen ist unbekannt, was der Import geändert
            // hat. Dann nichts löschen und den Import nicht verwerfen (§17).
            let mutations: [ImportMutation]
            if let data = batchEntity.mutationsJSON {
                do {
                    mutations = try JSONDecoder().decode([ImportMutation].self, from: data)
                } catch {
                    throw PersistenceDecodingError.invalidJSON(field: "ImportBatch.mutationsJSON")
                }
            } else {
                mutations = []
            }

            let transactionIDs = Set(mutations.map(\.transactionID))
            let transactionDescriptor = FetchDescriptor<SDTransactionEntity>(
                predicate: #Predicate { transactionIDs.contains($0.id) }
            )
            let rowsByID = Dictionary(
                uniqueKeysWithValues: try modelContext.fetch(transactionDescriptor).map { ($0.id, $0) }
            )
            var insertedIDs = Set<UUID>()
            var restoredTransactions: [Transaction] = []

            for mutation in mutations {
                guard let entity = rowsByID[mutation.transactionID] else { continue }
                switch mutation.kind {
                case .inserted:
                    insertedIDs.insert(mutation.transactionID)
                case .updated:
                    guard let snapshot = mutation.previousSnapshot else { continue }
                    let restored = try snapshot.restoring(id: mutation.transactionID)
                    entity.update(from: restored)
                    restoredTransactions.append(restored)
                }
            }

            // Eingefügte Buchungen verschwinden samt allem, was daran hängt
            // (Annotationen, Splits, Overrides, Zuordnungen, Belege).
            try deleteTransactionDependents(transactionIDs: insertedIDs)
            for id in insertedIDs {
                if let entity = rowsByID[id] { modelContext.delete(entity) }
            }
            try syncDerivedTransactionIndexes(for: restoredTransactions)
            modelContext.delete(batchEntity)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
