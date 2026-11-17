import Foundation
@preconcurrency import SwiftData

/// Teil von `PersistenceModelActor` (nach Thema aufgeteilt, Roadmap 7.3).
extension PersistenceModelActor {
    func loadBudgets() throws -> [Budget] {
        let rows = try modelContext.fetch(FetchDescriptor<SDBudget2Entity>())
        if !rows.isEmpty {
            // P2 Sparziele: 1:1-Sidecar joinen (nur Budgets mit Ziel haben
            // eine Zeile; korrupte Zielbeträge werfen statt 0 zu maskieren).
            let goals = try modelContext.fetch(FetchDescriptor<SDBudgetGoalEntity>())
            let goalByBudgetID = Dictionary(
                uniqueKeysWithValues: goals.map { ($0.budgetID, $0) }
            )
            let budgets = try rows.map { row -> Budget in
                var budget = try row.toDomain()
                if let goal = goalByBudgetID[row.id] {
                    budget.targetAmount = try goal.targetAmount()
                    budget.targetDate = goal.targetDate
                }
                return budget
            }
            return budgets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        // Legacy-Auto-Convert (Milestone F): V1-Budgets (Kategorie+Limit)
        // einmalig in Budget-2.0-Form übernehmen.
        let legacy = try modelContext.fetch(FetchDescriptor<SDBudgetEntity>())
        guard !legacy.isEmpty else { return [] }

        let categories = try modelContext.fetch(FetchDescriptor<SDCategoryEntity>())
        let namesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })

        var converted: [Budget] = []
        for row in legacy {
            guard let amount = Decimal(string: row.monthlyLimitValue) else { continue }
            converted.append(Budget(
                id: row.id,
                name: namesByID[row.categoryID] ?? "Budget",
                amount: amount,
                currency: .eur,
                categoryIDs: [row.categoryID],
                enabled: row.enabled
            ))
            modelContext.delete(row)
        }

        for budget in converted {
            modelContext.insert(SDBudget2Entity(from: budget))
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
        return converted.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func upsertBudgets(_ budgets: [Budget]) throws {
        guard !budgets.isEmpty else { return }
        let ids = Set(budgets.map(\.id))
        let descriptor = FetchDescriptor<SDBudget2Entity>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let existingByID = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(descriptor).map { ($0.id, $0) }
        )
        let goalDescriptor = FetchDescriptor<SDBudgetGoalEntity>(
            predicate: #Predicate { ids.contains($0.budgetID) }
        )
        let goalsByBudgetID = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(goalDescriptor).map { ($0.budgetID, $0) }
        )
        for budget in budgets {
            if let entity = existingByID[budget.id] {
                entity.update(from: budget)
            } else {
                modelContext.insert(SDBudget2Entity(from: budget))
            }
            // P2 Sparziel-Sidecar: nur bei gesetztem Ziel persistieren
            // (Ziel gelöscht → Zeile entfernen, kein nil-Geist).
            if budget.targetAmount != nil || budget.targetDate != nil {
                if let goal = goalsByBudgetID[budget.id] {
                    goal.update(targetAmount: budget.targetAmount, targetDate: budget.targetDate)
                } else {
                    modelContext.insert(SDBudgetGoalEntity(
                        budgetID: budget.id,
                        targetAmount: budget.targetAmount,
                        targetDate: budget.targetDate
                    ))
                }
            } else if let goal = goalsByBudgetID[budget.id] {
                modelContext.delete(goal)
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteBudget2(id: UUID) throws {
        let descriptor2 = FetchDescriptor<SDBudget2Entity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(descriptor2) {
            modelContext.delete(entity)
        }
        // P2: Sparziel-Sidecar gehört zum Budget-Scope (keine Orphans).
        let goalDescriptor = FetchDescriptor<SDBudgetGoalEntity>(
            predicate: #Predicate { $0.budgetID == id }
        )
        for goal in try modelContext.fetch(goalDescriptor) {
            modelContext.delete(goal)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteBudget(id: UUID) throws {
        // Legacy-Form
        let legacyDescriptor = FetchDescriptor<SDBudgetEntity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(legacyDescriptor) {
            modelContext.delete(entity)
        }

        let descriptor2 = FetchDescriptor<SDBudget2Entity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(descriptor2) {
            modelContext.delete(entity)
        }

        // P2: Sparziel-Sidecar gehört zum Budget-Scope (keine Orphans).
        let goalDescriptor = FetchDescriptor<SDBudgetGoalEntity>(
            predicate: #Predicate { $0.budgetID == id }
        )
        for goal in try modelContext.fetch(goalDescriptor) {
            modelContext.delete(goal)
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// Löscht eine Kategorie und hängt in EINEM Schreibvorgang alles um, was
    /// auf sie verweist (Roadmap #50: keine orphaned categoryIDs):
    /// Buchungen, Splitzeilen und Fixkosten bekommen `newCategoryID`
    /// (nil = „Ohne Kategorie"), in Budgets wird sie ersetzt bzw. entfernt,
    /// Regeln mit ihr als Ziel entfallen. Ein Verweis ins Leere ließe jedes
    /// spätere Backup an der Verweisprüfung der Wiederherstellung scheitern.
    func deleteCategory(id: UUID, reassignTo newCategoryID: UUID?) throws {
        let now = Date()
        let txnDescriptor = FetchDescriptor<SDTransactionEntity>(
            predicate: #Predicate { $0.categoryID == id }
        )
        for txn in try modelContext.fetch(txnDescriptor) {
            txn.categoryID = newCategoryID
        }

        let splitDescriptor = FetchDescriptor<SDTransactionSplitLineEntity>(
            predicate: #Predicate { $0.categoryID == id }
        )
        for line in try modelContext.fetch(splitDescriptor) {
            line.categoryID = newCategoryID
        }

        let commitmentDescriptor = FetchDescriptor<SDRecurringCommitmentEntity>(
            predicate: #Predicate { $0.categoryID == id }
        )
        for commitment in try modelContext.fetch(commitmentDescriptor) {
            commitment.categoryID = newCategoryID
            commitment.updatedAt = now
        }

        for budget in try modelContext.fetch(FetchDescriptor<SDBudget2Entity>()) {
            // Unlesbare Kategorie-Listen bleiben unangetastet (kein Überschreiben).
            guard var categoryIDs = JSONCoding.decodeUUIDs(budget.categoryIDsJSON),
                  categoryIDs.contains(id) else { continue }
            categoryIDs.removeAll { $0 == id }
            if let newCategoryID, !categoryIDs.contains(newCategoryID) {
                categoryIDs.append(newCategoryID)
            }
            budget.categoryIDsJSON = JSONCoding.encodeUUIDs(categoryIDs)
            budget.updatedAt = now
        }

        let ruleDescriptor = FetchDescriptor<SDRuleEntity>(
            predicate: #Predicate { $0.categoryID == id }
        )
        for rule in try modelContext.fetch(ruleDescriptor) {
            modelContext.delete(rule)
        }

        let categoryDescriptor = FetchDescriptor<SDCategoryEntity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(categoryDescriptor) {
            modelContext.delete(entity)
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
    }


    func loadTags() throws -> [Tag] {
        let rows = try modelContext.fetch(FetchDescriptor<SDTagEntity>())
        return rows.map { $0.toDomain() }
    }

    func upsertTags(_ tags: [Tag]) throws {
        for tag in tags {
            let id = tag.id
            let descriptor = FetchDescriptor<SDTagEntity>(
                predicate: #Predicate { $0.id == id }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                existing.update(from: tag)
            } else {
                modelContext.insert(SDTagEntity(from: tag))
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteTag(id: UUID) throws {
        let descriptor = FetchDescriptor<SDTagEntity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(descriptor) {
            modelContext.delete(entity)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }

        // Roadmap #14 / WP19: Relationen entfernen, Join-Rows per Pushdown
        // (Transaktionen bleiben unverändert), JSON-Bereinigung folgt.
        try deleteTagRows(tagID: id)
        removeTagID(id, fromAllAnnotations: true)
    }

    /// Entfernt eine tagID aus allen Annotationen (Orphan-Cleanup).
    func removeTagID(_ tagID: UUID, fromAllAnnotations: Bool) {
        guard fromAllAnnotations else { return }
        let descriptor = FetchDescriptor<SDTransactionAnnotationEntity>()
        var changed = false
        let entities = (try? modelContext.fetch(descriptor)) ?? []
        for entity in entities {
            guard let json = entity.tagIDsJSON,
                  var ids = try? JSONDecoder().decode([UUID].self, from: json),
                  ids.contains(tagID) else { continue }
            ids.removeAll { $0 == tagID }
            if let encoded = try? JSONEncoder().encode(ids) {
                entity.tagIDsJSON = encoded
                changed = true
            }
        }
        if changed {
            try? modelContext.save()
        }
    }
}
