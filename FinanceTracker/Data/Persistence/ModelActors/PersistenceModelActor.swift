import Foundation
import SwiftData

/// Schlanke Bewegungszeile für Konto-Aggregationen (ohne vollständige
/// Transaction-Hydratation).
@ModelActor
actor PersistenceModelActor {
    /// WP19: Einmal-Prozess-Gate für den Join-Row-Backfill.
    var tagJoinBackfillDone = false

    func loadTransactions(intervalStart: Date, intervalEnd: Date) throws -> [Transaction] {
        var descriptor = FetchDescriptor<SDTransactionEntity>()
        descriptor.predicate = #Predicate { entity in
            entity.effectiveDateValue != nil && entity.effectiveDateValue! >= intervalStart
                && entity.effectiveDateValue! < intervalEnd
        }
        let rows = try modelContext.fetch(descriptor)
        return try rows.map { try $0.toDomain() }
    }

    func countTransactions(intervalStart: Date, intervalEnd: Date) throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<SDTransactionEntity>(predicate: #Predicate { entity in
            entity.effectiveDateValue != nil && entity.effectiveDateValue! >= intervalStart
                && entity.effectiveDateValue! < intervalEnd
        }))
    }

    func loadAllTransactions() throws -> [Transaction] {
        let rows = try modelContext.fetch(FetchDescriptor<SDTransactionEntity>())
        return try rows.map { try $0.toDomain() }
    }

    /// MacUX-Automatisierung: Batch-Ladung nach IDs (ID-Pushdown).
    func loadTransactions(ids: Set<UUID>) throws -> [Transaction] {
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<SDTransactionEntity>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    /// Der potenziell große Bestandsabgleich bleibt vollständig auf dem
    /// ModelActor. Bewusste Kategorien werden durch das Predicate geschützt.
    func assignCategoriesToUncategorized(
        matching rules: [CategoryRule],
        assignableCategoryIDs: Set<Category.ID>
    ) throws -> Set<UUID> {
        let compiledRules = CategoryRuleEngine().compile(
            rules,
            assignableCategoryIDs: assignableCategoryIDs
        )
        var changedIDs = Set<UUID>()
        // Scheibenweise mit eigenem, kurzlebigem Kontext: Bei 100.000
        // offenen Buchungen hielte ein Durchgang sonst alle Zeilen als
        // Objekte im Speicher (siehe `lightRowSlices`).
        for slice in try lightRowSlices(sliceSize: 5_000) {
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            let range = slice.predicate
            let descriptor = FetchDescriptor<SDTransactionEntity>(
                predicate: #Predicate { $0.categoryID == nil && range.evaluate($0) }
            )
            for row in try context.fetch(descriptor) {
                var transaction = try row.toDomain()
                guard compiledRules.apply(to: &transaction) else { continue }
                row.categoryID = transaction.categoryID
                row.updatedAt = Date()
                changedIDs.insert(row.id)
            }
            if context.hasChanges {
                try context.save()
            }
        }
        return changedIDs
    }
    func loadTransactionsByAccount(
        intervalStart: Date,
        intervalEnd: Date,
        accountID: UUID,
        sourceRaw: String?
    ) throws -> [Transaction] {
        if let sourceRaw {
            return try loadTransactionsByAccountAndSource(
                intervalStart: intervalStart,
                intervalEnd: intervalEnd,
                accountID: accountID,
                sourceRaw: sourceRaw
            )
        }
        var descriptor = FetchDescriptor<SDTransactionEntity>()
        descriptor.predicate = #Predicate { entity in
            entity.accountID == accountID
                && entity.effectiveDateValue != nil && entity.effectiveDateValue! >= intervalStart
                && entity.effectiveDateValue! < intervalEnd
        }
        let rows = try modelContext.fetch(descriptor)
        return try rows.map { try $0.toDomain() }
    }

    func loadTransactionsByAccountAndSource(
        intervalStart: Date,
        intervalEnd: Date,
        accountID: UUID,
        sourceRaw: String
    ) throws -> [Transaction] {
        var descriptor = FetchDescriptor<SDTransactionEntity>()
        descriptor.predicate = #Predicate { entity in
            entity.accountID == accountID
                && entity.sourceRaw == sourceRaw
                && entity.effectiveDateValue != nil && entity.effectiveDateValue! >= intervalStart
                && entity.effectiveDateValue! < intervalEnd
        }
        let rows = try modelContext.fetch(descriptor)
        return try rows.map { try $0.toDomain() }
    }

    func loadTransactionsByAccounts(
        intervalStart: Date,
        intervalEnd: Date,
        accountIDs: Set<UUID>
    ) throws -> [Transaction] {
        guard !accountIDs.isEmpty else { return [] }
        var descriptor = FetchDescriptor<SDTransactionEntity>()
        descriptor.predicate = #Predicate { entity in
            accountIDs.contains(entity.accountID)
                && entity.effectiveDateValue != nil && entity.effectiveDateValue! >= intervalStart
                && entity.effectiveDateValue! < intervalEnd
        }
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    func loadTransactionsByAccountsAndSource(
        intervalStart: Date,
        intervalEnd: Date,
        accountIDs: Set<UUID>,
        sourceRaw: String
    ) throws -> [Transaction] {
        guard !accountIDs.isEmpty else { return [] }
        var descriptor = FetchDescriptor<SDTransactionEntity>()
        descriptor.predicate = #Predicate { entity in
            accountIDs.contains(entity.accountID)
                && entity.sourceRaw == sourceRaw
                && entity.effectiveDateValue != nil && entity.effectiveDateValue! >= intervalStart
                && entity.effectiveDateValue! < intervalEnd
        }
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    func loadTransactionsBySource(
        intervalStart: Date,
        intervalEnd: Date,
        sourceRaw: String
    ) throws -> [Transaction] {
        var descriptor = FetchDescriptor<SDTransactionEntity>()
        let source = sourceRaw
        descriptor.predicate = #Predicate { entity in
            entity.effectiveDateValue != nil && entity.effectiveDateValue! >= intervalStart
                && entity.effectiveDateValue! < intervalEnd
                && entity.sourceRaw == source
        }
        let rows = try modelContext.fetch(descriptor)
        return try rows.map { try $0.toDomain() }
    }

    func loadAccount(id: UUID) throws -> Account? {
        var descriptor = FetchDescriptor<SDAccountEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try applyingOpeningBalances(try modelContext.fetch(descriptor).map { try $0.toDomain() }).first
    }

    /// V13-Sidecar zusammenführen: Anfangsbestand/Stichtag an die Konten
    /// hängen. Strikt (#23): korrupte Beträge werfen statt 0.
    func applyingOpeningBalances(_ accounts: [Account]) throws -> [Account] {
        guard !accounts.isEmpty else { return accounts }
        let ids = accounts.map(\.id)
        let descriptor = FetchDescriptor<SDAccountOpeningBalanceEntity>(
            predicate: #Predicate { ids.contains($0.accountID) }
        )
        var byAccount: [UUID: SDAccountOpeningBalanceEntity] = [:]
        for row in try modelContext.fetch(descriptor) {
            byAccount[row.accountID] = row
        }
        let reportedDescriptor = FetchDescriptor<SDAccountReportedBalanceEntity>(
            predicate: #Predicate { ids.contains($0.accountID) }
        )
        var reportedByAccount: [UUID: SDAccountReportedBalanceEntity] = [:]
        for row in try modelContext.fetch(reportedDescriptor) {
            reportedByAccount[row.accountID] = row
        }
        let settingsDescriptor = FetchDescriptor<SDAccountSettingsEntity>(
            predicate: #Predicate { ids.contains($0.accountID) }
        )
        var settingsByAccount: [UUID: SDAccountSettingsEntity] = [:]
        for row in try modelContext.fetch(settingsDescriptor) {
            settingsByAccount[row.accountID] = row
        }
        let visibilityDescriptor = FetchDescriptor<SDAccountVisibilityEntity>(
            predicate: #Predicate { ids.contains($0.accountID) }
        )
        var hiddenAccountIDs = Set<UUID>()
        for row in try modelContext.fetch(visibilityDescriptor) where row.hiddenInList {
            hiddenAccountIDs.insert(row.accountID)
        }
        return try accounts.map { account in
            var updated = account
            if let row = byAccount[account.id] {
                updated.openingBalance = try row.decimalAmount()
                updated.openingBalanceDate = row.date
            }
            if let row = reportedByAccount[account.id] {
                updated.reportedBalance = try row.toDomain()
            }
            updated.excludedFromTotal = settingsByAccount[account.id]?.excludedFromTotal ?? false
            updated.isHiddenInList = hiddenAccountIDs.contains(account.id)
            return updated
        }
    }

    /// V14-Sidecar: gemeldeten Stand speichern. Ein älterer Stand ersetzt
    /// keinen neueren (z. B. ein alter Kontoauszug nach dem Bankabruf).
    func saveReportedBalance(_ balance: ReportedBalance, accountID: UUID) throws {
        let descriptor = FetchDescriptor<SDAccountReportedBalanceEntity>(
            predicate: #Predicate { $0.accountID == accountID }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            guard balance.asOf >= existing.asOf else { return }
            existing.update(balance)
        } else {
            modelContext.insert(SDAccountReportedBalanceEntity(accountID: accountID, balance: balance))
        }
        try modelContext.save()
    }

    func loadCategory(id: UUID) throws -> Category? {
        var descriptor = FetchDescriptor<SDCategoryEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    func loadMerchant(id: UUID) throws -> Merchant? {
        var descriptor = FetchDescriptor<SDMerchantEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    func loadRule(id: UUID) throws -> CategoryRule? {
        var descriptor = FetchDescriptor<SDRuleEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    func loadConnection(id: UUID) throws -> Connection? {
        var descriptor = FetchDescriptor<SDConnectionEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    func loadBudget(id: UUID) throws -> Budget? {
        var descriptor = FetchDescriptor<SDBudget2Entity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard var budget = try modelContext.fetch(descriptor).first?.toDomain() else {
            return nil
        }
        // P2 Sparziel-Sidecar joinen.
        var goalDescriptor = FetchDescriptor<SDBudgetGoalEntity>(
            predicate: #Predicate { $0.budgetID == id }
        )
        goalDescriptor.fetchLimit = 1
        if let goal = try modelContext.fetch(goalDescriptor).first {
            budget.targetAmount = try goal.targetAmount()
            budget.targetDate = goal.targetDate
        }
        return budget
    }

    /// WP20/§145: Category-Usage-Counts ohne Domain-Hydratation,
    /// nur die categoryID-Spalte lesen und in-memory zählen.
    func loadCategoryUsageCounts() throws -> [UUID: Int] {
        var descriptor = FetchDescriptor<SDTransactionEntity>()
        descriptor.propertiesToFetch = [\.categoryID]
        let rows = try modelContext.fetch(descriptor)
        var counts: [UUID: Int] = [:]
        for row in rows {
            guard let categoryID = row.categoryID else { continue }
            counts[categoryID, default: 0] += 1
        }
        return counts
    }

    func loadAccount(providerAccountID: String, connectionID: UUID) throws -> Account? {
        let descriptor = FetchDescriptor<SDAccountEntity>(
            predicate: #Predicate {
                $0.providerAccountID == providerAccountID && $0.connectionID == connectionID
            }
        )
        return try applyingOpeningBalances(try modelContext.fetch(descriptor).map { try $0.toDomain() }).first
    }

    func loadRecentTransactions(limit: Int) throws -> [Transaction] {
        var descriptor = FetchDescriptor<SDTransactionEntity>()
        descriptor.sortBy = [
            SortDescriptor(\.effectiveDateValue, order: .reverse),
            SortDescriptor(\.createdAt)
        ]
        descriptor.fetchLimit = limit
        let rows = try modelContext.fetch(descriptor)
        return try rows.map { try $0.toDomain() }
    }

    func loadTransactions(accountID: UUID, sourceRaw: String) throws -> [Transaction] {
        var descriptor = FetchDescriptor<SDTransactionEntity>()
        descriptor.predicate = #Predicate { entity in
            entity.accountID == accountID && entity.sourceRaw == sourceRaw
        }
        let rows = try modelContext.fetch(descriptor)
        return try rows.map { try $0.toDomain() }
    }

    /// Alle Buchungen der Konten, ohne Datumsgrenze (auch Zeilen ohne
    /// Buchungsdatum). Für Abfragen ohne Zeitraum, z. B. den Kontobestand
    /// beim Import, statt alle Buchungen zu laden und danach zu filtern.
    func loadTransactions(accountIDs: Set<UUID>) throws -> [Transaction] {
        let accounts = accountIDs
        let descriptor = FetchDescriptor<SDTransactionEntity>(
            predicate: #Predicate { accounts.contains($0.accountID) }
        )
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    func loadTransaction(id: UUID) throws -> Transaction? {
        let descriptor = FetchDescriptor<SDTransactionEntity>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entity = try modelContext.fetch(descriptor).first else { return nil }
        return try entity.toDomain()
    }

    /// Schlanke Konto-Bewegungszeilen (Roadmap #179): Nur die für Netto-
    /// Bewegungen nötigen Felder werden hydratisiert, kein vollständiges
    /// Transaction-Mapping pro Zeile.
    func loadAccountMovementRows() throws -> [AccountMovementRow] {
        var descriptor = FetchDescriptor<SDTransactionEntity>()
        descriptor.propertiesToFetch = [
            \.accountID,
            \.amountValue,
            \.amountCurrencyRaw,
            \.statusRaw,
            \.bookedAt,
            \.authorizedAt,
            \.createdAt
        ]
        return try modelContext.fetch(descriptor).map { row in
            guard TransactionStatus(rawValue: row.statusRaw) != nil else {
                throw PersistenceDecodingError.unknownStatus(raw: row.statusRaw)
            }
            guard let amount = Decimal(string: row.amountValue), !amount.isNaN else {
                throw PersistenceDecodingError.invalidAmount(field: "amount", raw: row.amountValue)
            }
            return AccountMovementRow(
                accountID: row.accountID,
                amountValue: row.amountValue,
                currencyRaw: row.amountCurrencyRaw,
                statusRaw: row.statusRaw,
                date: row.bookedAt ?? row.authorizedAt ?? row.createdAt
            )
        }
    }

    /// All rows and derived indexes are replaced in one save; no repository
    /// method with an intermediate commit participates in restore.
    func replaceBackupAtomically(_ backup: FinanceTrackerBackup) throws {
        try BackupRestoreService.validate(backup)
        modelContext.autosaveEnabled = false
        do {
            for row in try modelContext.fetch(FetchDescriptor<SDAccountEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDCategoryEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDMerchantEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDTransactionEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDRuleEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDImportBatchEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDConnectionEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDTransactionAnnotationEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDTagEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDBudgetEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDBudget2Entity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDTransactionSplitLineEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDRecurringCommitmentEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDRecurringOccurrenceEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDBudgetAmountHistoryEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDTransactionAttachmentEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDTransactionTagEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDTransactionSearchEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDTransactionCollectionEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDTransactionCollectionOverrideEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDBudgetGoalEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDSharedExpenseShareEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDAccountOpeningBalanceEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDAccountReportedBalanceEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDAccountSettingsEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<SDAccountVisibilityEntity>()) { modelContext.delete(row) }
            for row in backup.accounts {
                modelContext.insert(SDAccountEntity(from: row))
                if row.excludedFromTotal {
                    modelContext.insert(SDAccountSettingsEntity(accountID: row.id, excludedFromTotal: true))
                }
                if row.isHiddenInList {
                    modelContext.insert(SDAccountVisibilityEntity(accountID: row.id, hiddenInList: true))
                }
                if let opening = row.openingBalance {
                    modelContext.insert(SDAccountOpeningBalanceEntity(accountID: row.id, amount: opening, date: row.openingBalanceDate))
                }
                if let reported = row.reportedBalance {
                    modelContext.insert(SDAccountReportedBalanceEntity(accountID: row.id, balance: reported))
                }
            }
            for row in backup.categories { modelContext.insert(SDCategoryEntity(from: row)) }
            for row in backup.merchants { modelContext.insert(SDMerchantEntity(from: row)) }
            for row in backup.transactions { modelContext.insert(SDTransactionEntity(from: row)) }
            for row in backup.annotations { modelContext.insert(SDTransactionAnnotationEntity(from: row)) }
            for row in backup.rules { modelContext.insert(SDRuleEntity(from: row)) }
            for row in backup.tags { modelContext.insert(SDTagEntity(from: row)) }
            for row in backup.importBatches { modelContext.insert(SDImportBatchEntity(from: row)) }
            for row in backup.connections { modelContext.insert(SDConnectionEntity(from: row)) }
            for row in backup.budgets { modelContext.insert(SDBudget2Entity(from: row)) }
            for row in backup.budgetAmountHistory { modelContext.insert(SDBudgetAmountHistoryEntity(from: row)) }
            for row in backup.recurringCommitments { modelContext.insert(SDRecurringCommitmentEntity(from: row)) }
            for row in backup.splitLines { modelContext.insert(SDTransactionSplitLineEntity(from: row)) }
            for row in backup.sharedExpenseShares { modelContext.insert(SDSharedExpenseShareEntity(from: row)) }
            for row in backup.transactionCollectionOverrides { modelContext.insert(SDTransactionCollectionOverrideEntity(from: row)) }
            for row in backup.transactionCollections { modelContext.insert(try SDTransactionCollectionEntity(from: row)) }
            for row in backup.recurringOccurrences {
                modelContext.insert(SDRecurringOccurrenceEntity(id: row.id, commitmentID: row.commitmentID, transactionID: row.transactionID, createdAt: row.createdAt))
            }
            for row in backup.attachments {
                modelContext.insert(SDTransactionAttachmentEntity(id: row.id, transactionID: row.transactionID, fileName: row.fileName, mimeType: row.mimeType, localRelativePath: row.localRelativePath, createdAt: row.createdAt))
            }
            for budget in backup.budgets where budget.targetAmount != nil || budget.targetDate != nil {
                modelContext.insert(SDBudgetGoalEntity(budgetID: budget.id, targetAmount: budget.targetAmount, targetDate: budget.targetDate))
            }
            let annotations = Dictionary(uniqueKeysWithValues: backup.annotations.map { ($0.transactionID, $0) })
            try syncDerivedTransactionIndexes(for: backup.transactions, annotationOverrides: annotations)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func upsertTransactions(_ transactions: [Transaction]) throws {
        guard !transactions.isEmpty else { return }

        do {
            let transactionsByID = transactions.reduce(into: [UUID: Transaction]()) { result, transaction in
                result[transaction.id] = transaction
            }
            let normalizedTransactions = Array(transactionsByID.values)
            let ids = Set(transactionsByID.keys)
            let descriptor = FetchDescriptor<SDTransactionEntity>(
                predicate: #Predicate { ids.contains($0.id) }
            )
            let existingRows = try modelContext.fetch(descriptor)
            let existingByID = Dictionary(uniqueKeysWithValues: existingRows.map { ($0.id, $0) })

            for transaction in normalizedTransactions {
                if let entity = existingByID[transaction.id] {
                    entity.update(from: transaction)
                } else {
                    modelContext.insert(SDTransactionEntity(from: transaction))
                }
            }

            // WP19/WP38: Transaktionen und ihre abgeleiteten Indizes werden
            // aus denselben Domain-Werten und in demselben Save geschrieben.
            // Die Index-Bestände werden dabei je Tabelle einmalig gebündelt
            // geladen, unabhängig von der Batch-Größe.
            try syncDerivedTransactionIndexes(for: normalizedTransactions)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Hält Such- und Tag-Join-Index für einen Transaktions-Batch konsistent,
    /// ohne Fetches innerhalb der Transaktionsschleife auszuführen.
    func syncDerivedTransactionIndexes(
        for transactions: [Transaction],
        annotationOverrides: [UUID: TransactionAnnotation]? = nil
    ) throws {
        guard !transactions.isEmpty else { return }

        let transactionsByID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        let transactionIDs = Set(transactionsByID.keys)
        let annotationsByTransactionID: [UUID: TransactionAnnotation]
        if let annotationOverrides {
            annotationsByTransactionID = annotationOverrides
        } else {
            let annotationDescriptor = FetchDescriptor<SDTransactionAnnotationEntity>(
                predicate: #Predicate { transactionIDs.contains($0.transactionID) }
            )
            annotationsByTransactionID = Dictionary(
                uniqueKeysWithValues: try modelContext.fetch(annotationDescriptor).map {
                    ($0.transactionID, try $0.toDomain())
                }
            )
        }
        let resolver = EffectiveTransactionResolver()
        let effectiveTransactionsByID = transactionsByID.mapValues { transaction in
            guard let annotation = annotationsByTransactionID[transaction.id] else { return transaction }
            return resolver.applying(annotation: annotation, to: transaction)
        }

        let searchDescriptor = FetchDescriptor<SDTransactionSearchEntity>(
            predicate: #Predicate { transactionIDs.contains($0.transactionID) }
        )
        let searchRows = try modelContext.fetch(searchDescriptor)
        let searchRowsByTransactionID = Dictionary(grouping: searchRows, by: \.transactionID)

        for (transactionID, transaction) in effectiveTransactionsByID {
            let searchableText = SDTransactionEntity.buildSearchable(transaction) ?? ""
            if let rows = searchRowsByTransactionID[transactionID], let existing = rows.first {
                existing.searchableText = searchableText
                for duplicate in rows.dropFirst() {
                    modelContext.delete(duplicate)
                }
            } else {
                modelContext.insert(SDTransactionSearchEntity(
                    transactionID: transactionID,
                    searchableText: searchableText
                ))
            }
        }

        let tagDescriptor = FetchDescriptor<SDTransactionTagEntity>(
            predicate: #Predicate { transactionIDs.contains($0.transactionID) }
        )
        let tagRows = try modelContext.fetch(tagDescriptor)
        let tagRowsByTransactionID = Dictionary(grouping: tagRows, by: \.transactionID)

        for (transactionID, transaction) in effectiveTransactionsByID {
            let targetTagIDs = Set(transaction.tagIDs ?? [])
            let existingRows = tagRowsByTransactionID[transactionID] ?? []
            let existingRowsByTagID = Dictionary(grouping: existingRows, by: \.tagID)

            for (tagID, rows) in existingRowsByTagID {
                if targetTagIDs.contains(tagID) {
                    for duplicate in rows.dropFirst() {
                        modelContext.delete(duplicate)
                    }
                } else {
                    for row in rows {
                        modelContext.delete(row)
                    }
                }
            }
            for tagID in targetTagIDs where existingRowsByTagID[tagID] == nil {
                modelContext.insert(SDTransactionTagEntity(
                    transactionID: transactionID,
                    tagID: tagID
                ))
            }
        }
    }

    /// Entfernt die abgeleiteten Indexzeilen eines Transaktions-Batches mit
    /// je einem Fetch pro Tabelle. Der aufrufende Schreibpfad übernimmt Save
    /// bzw. Rollback gemeinsam mit den Parent-Zeilen.
    func deleteDerivedTransactionIndexes(transactionIDs: Set<UUID>) throws {
        guard !transactionIDs.isEmpty else { return }
        let searchDescriptor = FetchDescriptor<SDTransactionSearchEntity>(
            predicate: #Predicate { transactionIDs.contains($0.transactionID) }
        )
        for row in try modelContext.fetch(searchDescriptor) {
            modelContext.delete(row)
        }
        let tagDescriptor = FetchDescriptor<SDTransactionTagEntity>(
            predicate: #Predicate { transactionIDs.contains($0.transactionID) }
        )
        for row in try modelContext.fetch(tagDescriptor) {
            modelContext.delete(row)
        }
    }

    /// WP38: Suchindex-Zeile einer Transaktion aktualisieren (idempotent).
    func syncSearchRow(transactionID: UUID, text: String) {
        let descriptor = FetchDescriptor<SDTransactionSearchEntity>(
            predicate: #Predicate { $0.transactionID == transactionID }
        )
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.searchableText = text
        } else {
            modelContext.insert(SDTransactionSearchEntity(transactionID: transactionID, searchableText: text))
        }
    }

    /// WP38: Backfill on first use, Bestands-Transaktionen ohne Suchzeile
    /// nachziehen (idempotent, einmal pro Prozess).
    func ensureSearchIndexBackfill() throws {
        guard !searchIndexBackfillDone else { return }
        searchIndexBackfillDone = true
        try backfillSearchIndexIfNeeded()
    }

    private var searchIndexBackfillDone = false

    func backfillSearchIndexIfNeeded() throws {
        // Schnellweg: Jede Buchung bekommt ihre Suchzeile beim Speichern,
        // verwaiste Suchzeilen entfernt purgeOrphanedDependents beim Start.
        // Gleiche Anzahl heißt daher: nichts fehlt. Nur sonst der volle
        // Abgleich (bei 100.000 Buchungen sonst Sekunden bei der ersten Suche).
        let transactionCount = try modelContext.fetchCount(FetchDescriptor<SDTransactionEntity>())
        let indexCount = try modelContext.fetchCount(FetchDescriptor<SDTransactionSearchEntity>())
        guard transactionCount != indexCount else { return }
        let txnRows = try modelContext.fetch(FetchDescriptor<SDTransactionEntity>())
        let indexedIDs = Set(
            try modelContext.fetch(FetchDescriptor<SDTransactionSearchEntity>()).map(\.transactionID)
        )
        let missingTransactions = try txnRows
            .filter { !indexedIDs.contains($0.id) }
            .map { try $0.toDomain() }
        // Bestehende Annotation-Notizen sind Teil der effektiven Suche und
        // müssen auch beim Legacy-Backfill Vorrang vor Transaction-Facts haben.
        try syncDerivedTransactionIndexes(for: missingTransactions)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// WP38: SQL-Pushdown-Suche auf dem nicht-optionalen Index.
    func loadTransactionIDs(searchableNeedle: String) throws -> Set<UUID> {
        let descriptor = FetchDescriptor<SDTransactionSearchEntity>(
            predicate: #Predicate { $0.searchableText.contains(searchableNeedle) }
        )
        return Set(try modelContext.fetch(descriptor).map(\.transactionID))
    }

    func deleteAllBudgets() throws {
        // WP2 (§14): Budget-History gehört zum Budget-Scope.
        try modelContext.delete(model: SDBudgetAmountHistoryEntity.self)
        // P2: Sparziel-Sidecar gehört zum Budget-Scope.
        try modelContext.delete(model: SDBudgetGoalEntity.self)
        try modelContext.delete(model: SDBudgetEntity.self)
        try modelContext.delete(model: SDBudget2Entity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// WP2 (§14): Attachments, nur Metadaten; Dateien löscht der Aufrufer
    /// über AttachmentService (Dateisystem + Metadaten konsistent, §15).
    func deleteAllTransactionAttachments() throws {
        try modelContext.delete(model: SDTransactionAttachmentEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// WP2 (§14): Import-Batches vollständig entfernen.
    func deleteAllImportBatches() throws {
        try modelContext.delete(model: SDImportBatchEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// WP2 (§14): Connections entfernen (KEINE Keychain-Credentials, §16).
    func deleteAllConnections() throws {
        try modelContext.delete(model: SDConnectionEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// WP2 (§14): Tag-Join-Rows VOR den Tags löschen (§15).
    func deleteAllTags() throws {
        try modelContext.delete(model: SDTransactionTagEntity.self)
        try modelContext.delete(model: SDTagEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// WP2 (§14): Abgeleiteter Suchindex, gehört zum Transaction-Scope.
    func deleteAllSearchIndex() throws {
        try modelContext.delete(model: SDTransactionSearchEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteAllRecurringCommitments() throws {
        try modelContext.delete(model: SDRecurringOccurrenceEntity.self)
        try modelContext.delete(model: SDRecurringCommitmentEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteAllSplitLines() throws {
        try modelContext.delete(model: SDTransactionSplitLineEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func loadBudgetAmountHistory(budgetID: UUID?) throws -> [BudgetAmountHistory] {
        let descriptor: FetchDescriptor<SDBudgetAmountHistoryEntity>
        if let budgetID {
            descriptor = FetchDescriptor<SDBudgetAmountHistoryEntity>(
                predicate: #Predicate { $0.budgetID == budgetID }
            )
        } else {
            descriptor = FetchDescriptor<SDBudgetAmountHistoryEntity>()
        }
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    func upsertBudgetAmountHistory(_ entry: BudgetAmountHistory) throws {
        let descriptor = FetchDescriptor<SDBudgetAmountHistoryEntity>(
            predicate: #Predicate { $0.budgetID == entry.budgetID && $0.periodStart == entry.periodStart }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            existing.amountValue = NSDecimalNumber(decimal: entry.amount).stringValue
        } else {
            modelContext.insert(SDBudgetAmountHistoryEntity(from: entry))
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func loadTransactionAttachments(transactionID: UUID) throws -> [TransactionAttachment] {
        let descriptor = FetchDescriptor<SDTransactionAttachmentEntity>(
            predicate: #Predicate { $0.transactionID == transactionID }
        )
        return try modelContext.fetch(descriptor)
            .map { $0.toDomain() }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// WP29: Alle Attachment-Metadaten (Backup).
    func loadAllTransactionAttachments() throws -> [TransactionAttachment] {
        try modelContext.fetch(FetchDescriptor<SDTransactionAttachmentEntity>()).map { $0.toDomain() }
    }

    func addTransactionAttachment(_ attachment: TransactionAttachment) throws {
        modelContext.insert(SDTransactionAttachmentEntity(
            id: attachment.id,
            transactionID: attachment.transactionID,
            fileName: attachment.fileName,
            mimeType: attachment.mimeType,
            localRelativePath: attachment.localRelativePath,
            createdAt: attachment.createdAt
        ))
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteTransactionAttachment(id: UUID) throws {
        let descriptor = FetchDescriptor<SDTransactionAttachmentEntity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(descriptor) {
            modelContext.delete(entity)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func countTransactions() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<SDTransactionEntity>())
    }

    func deleteAllTransactions() throws {
        try modelContext.delete(model: SDTransactionEntity.self)
        // Alles, was nur zusammen mit einer Buchung Sinn ergibt, geht mit:
        // dieselbe Liste wie `deleteTransactionDependents`, hier tabellenweise.
        // Der Aufrufer muss diese Tabellen nicht vorher selbst leeren.
        try modelContext.delete(model: SDTransactionSearchEntity.self)
        try modelContext.delete(model: SDTransactionTagEntity.self)
        try modelContext.delete(model: SDSharedExpenseShareEntity.self)
        try modelContext.delete(model: SDTransactionAnnotationEntity.self)
        try modelContext.delete(model: SDTransactionSplitLineEntity.self)
        try modelContext.delete(model: SDTransactionCollectionOverrideEntity.self)
        try modelContext.delete(model: SDRecurringOccurrenceEntity.self)
        try modelContext.delete(model: SDTransactionAttachmentEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func loadTransactionAnnotations(transactionIDs: Set<UUID>) throws -> [TransactionAnnotation] {
        if transactionIDs.isEmpty {
            return try modelContext
                .fetch(FetchDescriptor<SDTransactionAnnotationEntity>())
                .map { try $0.toDomain() }
        }
        let descriptor = FetchDescriptor<SDTransactionAnnotationEntity>(
            predicate: #Predicate { transactionIDs.contains($0.transactionID) }
        )
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    func deleteTransactionAnnotation(transactionID: UUID) throws {
        do {
            let descriptor = FetchDescriptor<SDTransactionAnnotationEntity>(
                predicate: #Predicate { $0.transactionID == transactionID }
            )
            for entity in try modelContext.fetch(descriptor) {
                modelContext.delete(entity)
            }
            let transactionDescriptor = FetchDescriptor<SDTransactionEntity>(
                predicate: #Predicate { $0.id == transactionID }
            )
            if let row = try modelContext.fetch(transactionDescriptor).first {
                try syncDerivedTransactionIndexes(
                    for: [try row.toDomain()],
                    annotationOverrides: [:]
                )
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func loadTransactionAnnotation(transactionID: UUID) throws -> TransactionAnnotation? {
        let descriptor = FetchDescriptor<SDTransactionAnnotationEntity>(
            predicate: #Predicate { $0.transactionID == transactionID }
        )
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    func upsertTransactionAnnotations(_ annotations: [TransactionAnnotation]) throws {
        guard !annotations.isEmpty else { return }
        do {
            let annotationsByTransactionID = annotations.reduce(
                into: [UUID: TransactionAnnotation]()
            ) { result, annotation in
                result[annotation.transactionID] = annotation
            }
            let normalizedAnnotations = Array(annotationsByTransactionID.values)
            let transactionIDs = Set(annotationsByTransactionID.keys)
            let descriptor = FetchDescriptor<SDTransactionAnnotationEntity>(
                predicate: #Predicate { transactionIDs.contains($0.transactionID) }
            )
            let existingRows = try modelContext.fetch(descriptor)
            let existingByTransactionID = Dictionary(
                uniqueKeysWithValues: existingRows.map { ($0.transactionID, $0) }
            )

            for annotation in normalizedAnnotations {
                if let entity = existingByTransactionID[annotation.transactionID] {
                    entity.update(from: annotation)
                } else {
                    modelContext.insert(SDTransactionAnnotationEntity(from: annotation))
                }
            }

            let transactionDescriptor = FetchDescriptor<SDTransactionEntity>(
                predicate: #Predicate { transactionIDs.contains($0.id) }
            )
            let transactions = try modelContext.fetch(transactionDescriptor).map { try $0.toDomain() }
            try syncDerivedTransactionIndexes(
                for: transactions,
                annotationOverrides: annotationsByTransactionID
            )
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func deleteAllTransactionAnnotations() throws {
        do {
            let transactionIDs = Set(
                try modelContext.fetch(FetchDescriptor<SDTransactionAnnotationEntity>())
                    .map(\.transactionID)
            )
            try modelContext.delete(model: SDTransactionAnnotationEntity.self)
            if !transactionIDs.isEmpty {
                let transactionDescriptor = FetchDescriptor<SDTransactionEntity>(
                    predicate: #Predicate { transactionIDs.contains($0.id) }
                )
                let transactions = try modelContext.fetch(transactionDescriptor).map { try $0.toDomain() }
                try syncDerivedTransactionIndexes(for: transactions, annotationOverrides: [:])
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func loadAccounts() throws -> [Account] {
        let rows = try modelContext.fetch(FetchDescriptor<SDAccountEntity>())
        return try applyingOpeningBalances(rows.map { try $0.toDomain() })
    }

    func upsertAccounts(_ accounts: [Account]) throws {
        for account in accounts {
            let id = account.id
            let descriptor = FetchDescriptor<SDAccountEntity>(
                predicate: #Predicate { $0.id == id }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                existing.update(from: account)
            } else {
                modelContext.insert(SDAccountEntity(from: account))
            }
            try upsertOpeningBalance(for: account)
            try upsertSettings(for: account)
            try upsertVisibility(for: account)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// V15-Sidecar: nur Konten mit abweichender Einstellung haben eine Zeile.
    func upsertSettings(for account: Account) throws {
        let id = account.id
        let descriptor = FetchDescriptor<SDAccountSettingsEntity>(
            predicate: #Predicate { $0.accountID == id }
        )
        let existing = try modelContext.fetch(descriptor).first
        if account.excludedFromTotal {
            if let existing {
                if !existing.excludedFromTotal {
                    existing.excludedFromTotal = true
                    existing.updatedAt = Date()
                }
            } else {
                modelContext.insert(SDAccountSettingsEntity(accountID: id, excludedFromTotal: true))
            }
        } else if let existing {
            modelContext.delete(existing)
        }
    }

    /// V16-Sidecar: nur ausgeblendete Konten haben eine Zeile.
    func upsertVisibility(for account: Account) throws {
        let id = account.id
        let descriptor = FetchDescriptor<SDAccountVisibilityEntity>(
            predicate: #Predicate { $0.accountID == id }
        )
        let existing = try modelContext.fetch(descriptor).first
        if account.isHiddenInList {
            if let existing {
                if !existing.hiddenInList {
                    existing.hiddenInList = true
                    existing.updatedAt = Date()
                }
            } else {
                modelContext.insert(SDAccountVisibilityEntity(accountID: id, hiddenInList: true))
            }
        } else if let existing {
            modelContext.delete(existing)
        }
    }

    /// V13-Sidecar: Anfangsbestand anlegen, aktualisieren oder entfernen.
    func upsertOpeningBalance(for account: Account) throws {
        let id = account.id
        let descriptor = FetchDescriptor<SDAccountOpeningBalanceEntity>(
            predicate: #Predicate { $0.accountID == id }
        )
        let existing = try modelContext.fetch(descriptor).first
        if let amount = account.openingBalance {
            if let existing {
                existing.update(amount: amount, date: account.openingBalanceDate)
            } else {
                modelContext.insert(SDAccountOpeningBalanceEntity(accountID: id, amount: amount, date: account.openingBalanceDate))
            }
        } else if let existing {
            modelContext.delete(existing)
        }
    }

    func deleteAllAccounts() throws {
        try modelContext.delete(model: SDAccountEntity.self)
        try modelContext.delete(model: SDAccountOpeningBalanceEntity.self)
        try modelContext.delete(model: SDAccountReportedBalanceEntity.self)
        try modelContext.delete(model: SDAccountSettingsEntity.self)
        try modelContext.delete(model: SDAccountVisibilityEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// WP-UX: Nur Demo-Seed-Rows (Source = demo) entfernen, echte
    /// openBanking/manual-Daten bleiben.
    func deleteAllDemoTransactions() throws {
        do {
            let source = "demo"
            let descriptor = FetchDescriptor<SDTransactionEntity>(
                predicate: #Predicate { $0.sourceRaw == source }
            )
            let rows = try modelContext.fetch(descriptor)
            // Derselbe Weg wie jedes andere Löschen von Buchungen, damit
            // Anmerkungen, Splits, Zuordnungen und Belege nicht verwaisen.
            try deleteTransactionRowsWithDependents(rows)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Entfernt ein Konto samt aller seiner Buchungen und der daran
    /// hängenden Zeilen (Suchindex, Tags, Anteile, Annotationen, Splits,
    /// Anfangsbestand) in einem Schritt, entweder alles oder nichts.
    func deleteAccountWithTransactions(accountID: UUID) throws {
        do {
            let transactions = try modelContext.fetch(FetchDescriptor<SDTransactionEntity>(
                predicate: #Predicate { $0.accountID == accountID }
            ))
            try deleteTransactionRowsWithDependents(transactions)
            for row in try modelContext.fetch(FetchDescriptor<SDAccountOpeningBalanceEntity>(
                predicate: #Predicate { $0.accountID == accountID }
            )) {
                modelContext.delete(row)
            }
            for row in try modelContext.fetch(FetchDescriptor<SDAccountReportedBalanceEntity>(
                predicate: #Predicate { $0.accountID == accountID }
            )) {
                modelContext.delete(row)
            }
            for row in try modelContext.fetch(FetchDescriptor<SDAccountSettingsEntity>(
                predicate: #Predicate { $0.accountID == accountID }
            )) {
                modelContext.delete(row)
            }
            for row in try modelContext.fetch(FetchDescriptor<SDAccountVisibilityEntity>(
                predicate: #Predicate { $0.accountID == accountID }
            )) {
                modelContext.delete(row)
            }
            for row in try modelContext.fetch(FetchDescriptor<SDAccountEntity>(
                predicate: #Predicate { $0.id == accountID }
            )) {
                modelContext.delete(row)
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Entfernt einzelne Buchungen samt aller daran hängenden Zeilen (atomar).
    func deleteTransactions(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        do {
            let rows = try modelContext.fetch(FetchDescriptor<SDTransactionEntity>(
                predicate: #Predicate { ids.contains($0.id) }
            ))
            try deleteTransactionRowsWithDependents(rows)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Alle Zeilen, die nur zusammen mit einer Buchung Sinn ergeben:
    /// Suchindex, Tags, Anteile, Annotationen, Splits, Sammlungs-Overrides,
    /// Zuordnungen zu Zahlungsplänen und Beleg-Metadaten. Jeder Löschpfad
    /// für Buchungen läuft hierüber, damit keiner etwas vergisst (sonst
    /// lehnt die Wiederherstellung spätere Backups ab). Speichert NICHT.
    func deleteTransactionDependents(transactionIDs: Set<UUID>) throws {
        guard !transactionIDs.isEmpty else { return }
        try deleteDerivedTransactionIndexes(transactionIDs: transactionIDs)
        try deleteSharedExpenseShareRows(transactionIDs: transactionIDs)
        for row in try modelContext.fetch(FetchDescriptor<SDTransactionAnnotationEntity>(
            predicate: #Predicate { transactionIDs.contains($0.transactionID) }
        )) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<SDTransactionSplitLineEntity>(
            predicate: #Predicate { transactionIDs.contains($0.parentTransactionID) }
        )) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<SDTransactionCollectionOverrideEntity>(
            predicate: #Predicate { transactionIDs.contains($0.transactionID) }
        )) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<SDRecurringOccurrenceEntity>(
            predicate: #Predicate { transactionIDs.contains($0.transactionID) }
        )) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<SDTransactionAttachmentEntity>(
            predicate: #Predicate { transactionIDs.contains($0.transactionID) }
        )) {
            modelContext.delete(row)
        }
    }

    /// Datumsabfragen nutzen den Index auf `effectiveDateValue` und lassen
    /// Zeilen ohne Wert deshalb aus. Jede Schreibstelle setzt ihn (Anzeige-
    /// datum, notfalls Anlagezeit); ältere Zeilen ohne Wert holt dieser
    /// Schritt beim Start nach. Liefert die Anzahl ergänzter Zeilen.
    func backfillMissingSortDates() throws -> Int {
        let descriptor = FetchDescriptor<SDTransactionEntity>(
            predicate: #Predicate { $0.effectiveDateValue == nil }
        )
        let rows = try modelContext.fetch(descriptor)
        guard !rows.isEmpty else { return 0 }
        for row in rows {
            row.effectiveDateValue = row.bookedAt ?? row.authorizedAt ?? row.valueDate ?? row.createdAt
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        return rows.count
    }

    /// Einmalige Reparatur: Zeilen, deren Buchung fehlt (frühere Lücken im
    /// Import-Rückgängig), blockierten die Wiederherstellung jedes späteren
    /// Backups. Speichert selbst; liefert die Anzahl entfernter Zeilen.
    /// Läuft bei jedem Start. Damit der Speicher auch bei 100.000
    /// Buchungen klein bleibt (der Suchindex allein hat eine Zeile je
    /// Buchung), werden die abhängigen Zeilen in Stücken mit eigenem,
    /// kurzlebigem Kontext gelesen und nur die darin genannten Buchungen
    /// nachgeschlagen. Gelöscht wird nur, was als verwaist bestätigt ist.
    func purgeOrphanedTransactionDependents() throws -> Int {
        var removed = 0
        removed += try purgeOrphans(SDTransactionAnnotationEntity.self, \.transactionID) { ids in #Predicate { ids.contains($0.transactionID) } }
        removed += try purgeOrphans(SDTransactionSplitLineEntity.self, \.parentTransactionID) { ids in #Predicate { ids.contains($0.parentTransactionID) } }
        removed += try purgeOrphans(SDTransactionCollectionOverrideEntity.self, \.transactionID) { ids in #Predicate { ids.contains($0.transactionID) } }
        removed += try purgeOrphans(SDRecurringOccurrenceEntity.self, \.transactionID) { ids in #Predicate { ids.contains($0.transactionID) } }
        removed += try purgeOrphans(SDSharedExpenseShareEntity.self, \.transactionID) { ids in #Predicate { ids.contains($0.transactionID) } }
        removed += try purgeOrphans(SDTransactionSearchEntity.self, \.transactionID) { ids in #Predicate { ids.contains($0.transactionID) } }
        removed += try purgeOrphans(SDTransactionTagEntity.self, \.transactionID) { ids in #Predicate { ids.contains($0.transactionID) } }
        removed += try purgeOrphans(SDTransactionAttachmentEntity.self, \.transactionID) { ids in #Predicate { ids.contains($0.transactionID) } }
        return removed
    }

    private func purgeOrphans<T: PersistentModel>(
        _ type: T.Type,
        _ transactionID: KeyPath<T, UUID>,
        referencing: (Set<UUID>) -> Predicate<T>
    ) throws -> Int {
        let chunkSize = 2_000
        var orphanIDs = Set<UUID>()
        var offset = 0
        while true {
            let context = ModelContext(modelContainer)
            var descriptor = FetchDescriptor<T>()
            descriptor.propertiesToFetch = [transactionID]
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = chunkSize
            let referenced = Set(try context.fetch(descriptor).map { $0[keyPath: transactionID] })
            if referenced.isEmpty { break }
            var existingDescriptor = FetchDescriptor<SDTransactionEntity>(
                predicate: #Predicate { referenced.contains($0.id) }
            )
            existingDescriptor.propertiesToFetch = [\.id]
            let existing = Set(try context.fetch(existingDescriptor).map(\.id))
            orphanIDs.formUnion(referenced.subtracting(existing))
            offset += chunkSize
        }
        guard !orphanIDs.isEmpty else { return 0 }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let rows = try context.fetch(FetchDescriptor<T>(predicate: referencing(orphanIDs)))
        rows.forEach(context.delete)
        try context.save()
        return rows.count
    }

    /// Löscht Buchungszeilen und alles, was nur mit ihnen Sinn ergibt:
    /// Suchindex, Tags, Anteile, Annotationen, Splits, Sammlungs-Overrides
    /// und Zuordnungen zu Zahlungsplänen. Speichert NICHT: der Aufrufer
    /// entscheidet über save/rollback.
    func deleteTransactionRowsWithDependents(_ rows: [SDTransactionEntity]) throws {
        let transactionIDs = Set(rows.map(\.id))
        guard !transactionIDs.isEmpty else { return }
        try deleteTransactionDependents(transactionIDs: transactionIDs)
        // Importe, deren Buchungen damit vollständig verschwinden, sollen
        // nicht als leere Einträge in „Letzte Imports" stehen bleiben.
        // Importe, die zusätzlich bestehende Buchungen aktualisiert haben,
        // bleiben: ihr Rückgängig stellt diese Aktualisierungen noch her.
        let batchIDs = Set(rows.compactMap(\.importBatchID))
        for batchID in batchIDs {
            let remaining = try modelContext.fetch(FetchDescriptor<SDTransactionEntity>(
                predicate: #Predicate { $0.importBatchID == batchID }
            )).filter { !transactionIDs.contains($0.id) }
            guard remaining.isEmpty else { continue }
            for batch in try modelContext.fetch(FetchDescriptor<SDImportBatchEntity>(
                predicate: #Predicate { $0.id == batchID }
            )) where batch.updatedCount == 0 {
                modelContext.delete(batch)
            }
        }
        for row in rows {
            modelContext.delete(row)
        }
    }

    func deleteAllDemoAccounts() throws {
        let source = "demo"
        let descriptor = FetchDescriptor<SDAccountEntity>(
            predicate: #Predicate { $0.sourceRaw == source }
        )
        var deletedIDs: [UUID] = []
        for row in try modelContext.fetch(descriptor) {
            deletedIDs.append(row.id)
            modelContext.delete(row)
        }
        if !deletedIDs.isEmpty {
            let openings = FetchDescriptor<SDAccountOpeningBalanceEntity>(
                predicate: #Predicate { deletedIDs.contains($0.accountID) }
            )
            for row in try modelContext.fetch(openings) {
                modelContext.delete(row)
            }
            let reported = FetchDescriptor<SDAccountReportedBalanceEntity>(
                predicate: #Predicate { deletedIDs.contains($0.accountID) }
            )
            for row in try modelContext.fetch(reported) {
                modelContext.delete(row)
            }
            let settings = FetchDescriptor<SDAccountSettingsEntity>(
                predicate: #Predicate { deletedIDs.contains($0.accountID) }
            )
            for row in try modelContext.fetch(settings) {
                modelContext.delete(row)
            }
            let visibility = FetchDescriptor<SDAccountVisibilityEntity>(
                predicate: #Predicate { deletedIDs.contains($0.accountID) }
            )
            for row in try modelContext.fetch(visibility) {
                modelContext.delete(row)
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func loadCategories() throws -> [Category] {
        let rows = try modelContext.fetch(FetchDescriptor<SDCategoryEntity>())
        return rows.map { $0.toDomain() }
    }

    func upsertCategories(_ categories: [Category]) throws {
        for category in categories {
            let id = category.id
            let descriptor = FetchDescriptor<SDCategoryEntity>(
                predicate: #Predicate { $0.id == id }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                existing.update(from: category)
            } else {
                modelContext.insert(SDCategoryEntity(from: category))
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteAllCategories() throws {
        try modelContext.delete(model: SDCategoryEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func loadMerchants() throws -> [Merchant] {
        let rows = try modelContext.fetch(FetchDescriptor<SDMerchantEntity>())
        return rows.map { $0.toDomain() }
    }

    func upsertMerchants(_ merchants: [Merchant]) throws {
        for merchant in merchants {
            let id = merchant.id
            let descriptor = FetchDescriptor<SDMerchantEntity>(
                predicate: #Predicate { $0.id == id }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                existing.update(from: merchant)
            } else {
                modelContext.insert(SDMerchantEntity(from: merchant))
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteAllMerchants() throws {
        try modelContext.delete(model: SDMerchantEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func loadRules() throws -> [CategoryRule] {
        let rows = try modelContext.fetch(FetchDescriptor<SDRuleEntity>())
        return try rows.map { try $0.toDomain() }
    }

    func upsertRules(_ rules: [CategoryRule]) throws {
        for rule in rules {
            let id = rule.id
            let descriptor = FetchDescriptor<SDRuleEntity>(
                predicate: #Predicate { $0.id == id }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                existing.update(from: rule)
            } else {
                modelContext.insert(SDRuleEntity(from: rule))
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteRule(id: UUID) throws {
        let descriptor = FetchDescriptor<SDRuleEntity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(descriptor) {
            modelContext.delete(entity)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteTransactions(importBatchID: UUID) throws {
        do {
            let descriptor = FetchDescriptor<SDTransactionEntity>(
                predicate: #Predicate { $0.importBatchID == importBatchID }
            )
            let rows = try modelContext.fetch(descriptor)
            try deleteTransactionRowsWithDependents(rows)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func loadImportBatches() throws -> [ImportBatch] {
        let rows = try modelContext.fetch(FetchDescriptor<SDImportBatchEntity>())
        return try rows.map { try $0.toDomain() }
    }

    /// WP14: Nur der letzte Import, kein Full-Fetch für den Dashboard-Hinweis.
    func loadLatestImportBatch() throws -> ImportBatch? {
        var descriptor = FetchDescriptor<SDImportBatchEntity>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    func upsertImportBatches(_ batches: [ImportBatch]) throws {
        for batch in batches {
            let id = batch.id
            let descriptor = FetchDescriptor<SDImportBatchEntity>(
                predicate: #Predicate { $0.id == id }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                existing.update(from: batch)
            } else {
                modelContext.insert(SDImportBatchEntity(from: batch))
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func loadConnections() throws -> [Connection] {
        let rows = try modelContext.fetch(FetchDescriptor<SDConnectionEntity>())
        return try rows.map { try $0.toDomain() }
    }

    func upsertConnections(_ connections: [Connection]) throws {
        for connection in connections {
            let id = connection.id
            let descriptor = FetchDescriptor<SDConnectionEntity>(
                predicate: #Predicate { $0.id == id }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                existing.update(from: connection)
            } else {
                modelContext.insert(SDConnectionEntity(from: connection))
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func loadConnection(providerConnectionID: String) throws -> Connection? {
        let descriptor = FetchDescriptor<SDConnectionEntity>(
            predicate: #Predicate { $0.providerConnectionID == providerConnectionID }
        )
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    func deleteConnection(id: UUID) throws {
        let descriptor = FetchDescriptor<SDConnectionEntity>(
            predicate: #Predicate { $0.id == id }
        )
        for entity in try modelContext.fetch(descriptor) {
            modelContext.delete(entity)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteImportBatch(id: UUID) throws {
        let descriptor = FetchDescriptor<SDImportBatchEntity>(
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
