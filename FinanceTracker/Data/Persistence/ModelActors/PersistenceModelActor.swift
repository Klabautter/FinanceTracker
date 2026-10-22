import Foundation
import SwiftData

/// Schlanke Bewegungszeile für Konto-Aggregationen (ohne vollständige
/// Transaction-Hydratation).
struct AccountMovementRow: Sendable {
    let accountID: UUID
    let amountValue: String
    let currencyRaw: String
    let statusRaw: String
    /// Anzeigedatum (gebucht, sonst autorisiert, sonst angelegt), für den
    /// Kontostand ab Anfangsbestand-Stichtag.
    let date: Date
}

@ModelActor
actor PersistenceModelActor {
    func loadTransactions(intervalStart: Date, intervalEnd: Date) throws -> [Transaction] {
        var descriptor = FetchDescriptor<SDTransactionEntity>()
        descriptor.predicate = #Predicate { entity in
            (entity.effectiveDateValue ?? entity.createdAt) >= intervalStart
                && (entity.effectiveDateValue ?? entity.createdAt) < intervalEnd
        }
        let rows = try modelContext.fetch(descriptor)
        return try rows.map { try $0.toDomain() }
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
        let descriptor = FetchDescriptor<SDTransactionEntity>(
            predicate: #Predicate { $0.categoryID == nil }
        )
        let compiledRules = CategoryRuleEngine().compile(
            rules,
            assignableCategoryIDs: assignableCategoryIDs
        )
        var changedIDs = Set<UUID>()

        for row in try modelContext.fetch(descriptor) {
            var transaction = try row.toDomain()
            guard compiledRules.apply(to: &transaction) else { continue }
            row.categoryID = transaction.categoryID
            row.updatedAt = Date()
            changedIDs.insert(row.id)
        }
        if modelContext.hasChanges {
            try modelContext.save()
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
                && (entity.effectiveDateValue ?? entity.createdAt) >= intervalStart
                && (entity.effectiveDateValue ?? entity.createdAt) < intervalEnd
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
                && (entity.effectiveDateValue ?? entity.createdAt) >= intervalStart
                && (entity.effectiveDateValue ?? entity.createdAt) < intervalEnd
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
                && (entity.effectiveDateValue ?? entity.createdAt) >= intervalStart
                && (entity.effectiveDateValue ?? entity.createdAt) < intervalEnd
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
                && (entity.effectiveDateValue ?? entity.createdAt) >= intervalStart
                && (entity.effectiveDateValue ?? entity.createdAt) < intervalEnd
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
            (entity.effectiveDateValue ?? entity.createdAt) >= intervalStart
                && (entity.effectiveDateValue ?? entity.createdAt) < intervalEnd
                && entity.sourceRaw == source
        }
        let rows = try modelContext.fetch(descriptor)
        return try rows.map { try $0.toDomain() }
    }

    func loadTransactionPage(
        intervalStart: Date?,
        intervalEnd: Date?,
        searchText: String,
        accountIDs: Set<UUID>,
        sourceRaws: Set<String>,
        statusRaws: Set<String> = [],
        categoryIDs: Set<UUID>,
        tagIDs: Set<UUID>,
        tagMatchMode: TagMatchMode = .any,
        merchantSort: Bool?,
        amountSort: Bool?,
        ascending: Bool,
        offset: Int,
        limit: Int
    ) throws -> TransactionPage {
        var descriptor = FetchDescriptor<SDTransactionEntity>()

        let start = intervalStart ?? .distantPast
        let end = intervalEnd ?? .distantFuture
        let needle = searchText
        let hasSearch = !needle.isEmpty
        let accounts = accountIDs
        let sources = sourceRaws
        let hasAccountFilter = !accounts.isEmpty
        let hasSourceFilter = !sources.isEmpty
        let statuses = statusRaws
        let hasStatusFilter = !statuses.isEmpty
        // WP8 (§65): Category-Filter als SET, Parent-Filter expandiert auf
        // mehrere Descendant-IDs; ein Single-ID-Spezialfall würde den
        // Filter still verlieren.
        let catIDs = categoryIDs
        // In-Memory-Korrekturfilter: CoreData kann für „optional IN set"
        // KEIN SQL generieren (TERNARY-Absturz). Category-Filterung läuft
        // deshalb nach der effektiven Splitzuordnung in-memory.
        let matchesAccountAndSource: (SDTransactionEntity) -> Bool = { row in
            (!hasAccountFilter || accounts.contains(row.accountID))
                && (!hasSourceFilter || sources.contains(row.sourceRaw))
                && (!hasStatusFilter || statuses.contains(row.statusRaw))
        }
        // WP38: Gefoldeter Needle (identische Normalisierung wie der Index).
        let foldedNeedle = needle
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()

        // Sichere SQL-Vorfilter: Datum, Konto und Quelle. Kategorien werden
        // nach Splitzuordnung geprüft; Tags/Suche über ihre ID-Mengen.
        descriptor.predicate = #Predicate { entity in
            (entity.effectiveDateValue ?? entity.createdAt) >= start
                && (entity.effectiveDateValue ?? entity.createdAt) < end
                && (!hasAccountFilter || accounts.contains(entity.accountID))
                && (!hasSourceFilter || sources.contains(entity.sourceRaw))
        }
        // Der Statusfilter läuft bewusst NICHT im SQL-Prädikat (ein weiterer
        // Term sprengt den Typ-Checker des Makros), sondern wie der
        // Kategorie-Filter vor dem Seitenschnitt über die gesamte Treffermenge.
        let matchesStatus: (SDTransactionEntity) -> Bool = { row in
            !hasStatusFilter || statuses.contains(row.statusRaw)
        }

        var splitCategoriesByParent: [UUID: Set<UUID>] = [:]
        if !catIDs.isEmpty {
            var scopedIDsDescriptor = descriptor
            scopedIDsDescriptor.propertiesToFetch = [\.id]
            let scopedIDs = Set(try modelContext.fetch(scopedIDsDescriptor).map(\.id))
            for line in try loadSplitLines(parentTransactionIDs: scopedIDs) {
                splitCategoriesByParent[line.parentTransactionID, default: []].formUnion(
                    line.categoryID.map { [$0] } ?? []
                )
            }
        }
        let splitCategories = splitCategoriesByParent
        let matchesCategory: (SDTransactionEntity) -> Bool = { row in
            guard !catIDs.isEmpty else { return true }
            if let attributed = splitCategories[row.id] {
                return !attributed.isDisjoint(with: catIDs)
            }
            return row.categoryID.map { catIDs.contains($0) } ?? false
        }

        // WP21: Date-Sort bleibt DB-seitig; Merchant/Amount werden über die
        // GESAMTE Match-Menge (light rows, propertiesToFetch) sortiert, bevor
        // die Seite geschnitten wird, damit bleibt die Reihenfolge über alle
        // Seiten korrekt statt nur innerhalb der geladenen Seite. Kein FX:
        // Amount-Sortierung gruppiert primär nach Währung.
        let needsInMemorySort = merchantSort != nil || amountSort != nil
        if merchantSort == nil, amountSort == nil {
            descriptor.sortBy = [
                SortDescriptor(\.effectiveDateValue, order: ascending ? .forward : .reverse),
                SortDescriptor(\.createdAt)
            ]
        }

        // WP19: Tag-ANY-Filter, tagged IDs aus der Join-Tabelle (Pushdown),
        // Intersect gegen den datums-/sortierten Stream (Korrektheitsnetz).
        let taggedSet: Set<UUID>? = tagIDs.isEmpty
            ? nil
            : try loadTransactionIDs(tagIDs: tagIDs, mode: tagMatchMode)

        if let taggedSet, !hasSearch, !needsInMemorySort {
            // WP38: Join-First statt Stream-Filterung, die tagged IDs sind
            // aus der Join-Tabelle bekannt; sie werden in ID-Chunks direkt
            // geholt (Datum-Pushdown + Sortierung pro Chunk), nur die
            // Treffer werden hydratiert. Category-Filter in-memory (§65).
            var collected: [SDTransactionEntity] = []
            let idArray = Array(taggedSet)
            var index = 0
            while index < idArray.count {
                let ids = Set(idArray[index..<min(index + 400, idArray.count)])
                var chunkDescriptor = descriptor
                chunkDescriptor.predicate = #Predicate { entity in
                    ids.contains(entity.id)
                        && (entity.effectiveDateValue ?? entity.createdAt) >= start
                        && (entity.effectiveDateValue ?? entity.createdAt) < end
                }
                collected += try modelContext.fetch(chunkDescriptor).filter {
                    matchesAccountAndSource($0) && matchesCategory($0)
                }
                index += 400
            }

            if ascending {
                collected.sort {
                    ($0.effectiveDateValue ?? $0.createdAt, $0.createdAt)
                        < ($1.effectiveDateValue ?? $1.createdAt, $1.createdAt)
                }
            } else {
                // Wie die DB-Sortierung: Datum absteigend, bei gleichem Datum
                // Anlagezeit AUFSTEIGEND, sonst ändert ein Filter die
                // Reihenfolge innerhalb eines Tages.
                collected.sort {
                    let lhs = $0.effectiveDateValue ?? $0.createdAt
                    let rhs = $1.effectiveDateValue ?? $1.createdAt
                    return lhs != rhs ? lhs > rhs : $0.createdAt < $1.createdAt
                }
            }

            let pageRows = Array(collected.dropFirst(offset).prefix(limit))
            let hasMore = collected.count > offset + limit
            let mapped = try pageRows.map { try $0.toDomain() }
            return TransactionPage(transactions: mapped, hasMore: hasMore)
        }

        // WP21: Merchant/Amount-Sortierung, light rows der GESAMTEN Match-
        // Menge lesen (propertiesToFetch), in-memory sortieren, dann die
        // Seite hydratieren. Kein Domain-Full-Hydration, kein Schema-Index.
        if needsInMemorySort {
            var lightDescriptor = descriptor
            lightDescriptor.propertiesToFetch = [
                \.id, \.effectiveDateValue, \.createdAt,
                \.rawMerchantName, \.merchantDisplayName,
                \.amountValue, \.amountCurrencyRaw, \.categoryID, \.statusRaw
            ]
            var lightRows = try modelContext.fetch(lightDescriptor)
            if hasStatusFilter {
                lightRows = lightRows.filter(matchesStatus)
            }
            // WP19×WP21: Tag-Intersect auch im In-Memory-Sort-Pfad.
            if let taggedSet {
                lightRows = lightRows.filter { taggedSet.contains($0.id) }
            }
            // WP8×WP21: Category-Set-Intersect im Sort-Pfad (§65).
            if !catIDs.isEmpty {
                lightRows = lightRows.filter(matchesCategory)
            }
            // WP38: Such-Intersect im In-Memory-Sort-Pfad (Search+Sort-Kombi).
            if hasSearch {
                let searchIDs = try loadTransactionIDs(searchableNeedle: foldedNeedle)
                lightRows = lightRows.filter { searchIDs.contains($0.id) }
            }

            struct SortKey {
                let id: UUID
                let merchant: String
                let currency: String
                let amount: Decimal
            }
            let keys: [SortKey] = lightRows.map { row in
                SortKey(
                    id: row.id,
                    merchant: (row.merchantDisplayName ?? row.rawMerchantName ?? "")
                        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil),
                    currency: row.amountCurrencyRaw,
                    amount: Decimal(string: row.amountValue) ?? 0
                )
            }

            let ascendingDirection = merchantSort == true || amountSort == true
            let sortedKeys: [SortKey]
            if merchantSort != nil {
                sortedKeys = keys.sorted {
                    let result = $0.merchant.compare($1.merchant, options: [.caseInsensitive, .diacriticInsensitive])
                    let ascending = merchantSort == true
                    return ascending ? result == .orderedAscending : result == .orderedDescending
                }
            } else {
                // Währung primär (alphabetisch), Betrag in der Währung sekundär.
                sortedKeys = keys.sorted { lhs, rhs in
                    if lhs.currency != rhs.currency {
                        return amountSort == true
                            ? lhs.currency < rhs.currency
                            : lhs.currency > rhs.currency
                    }
                    return amountSort == true
                        ? lhs.amount < rhs.amount
                        : lhs.amount > rhs.amount
                }
            }
            _ = ascendingDirection

            let pageKeys = Array(sortedKeys.dropFirst(offset).prefix(limit))
            let hasMore = sortedKeys.count > offset + limit
            let pageIDs = Set(pageKeys.map(\.id))

            guard !pageIDs.isEmpty else {
                return TransactionPage(transactions: [], hasMore: false)
            }

            var pageDescriptor = descriptor
            let ids = pageIDs
            pageDescriptor.predicate = #Predicate { entity in
                ids.contains(entity.id)
            }
            pageDescriptor.fetchOffset = 0
            pageDescriptor.fetchLimit = limit
            let rows = try modelContext.fetch(pageDescriptor)
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let ordered = pageKeys.compactMap { key in byID[key.id] }
            let mapped = try ordered.map { try $0.toDomain() }
            return TransactionPage(transactions: mapped, hasMore: hasMore)
        }

        if hasSearch {
            // WP38: SQL-Pushdown auf dem nicht-optionalen Suchindex.
            try ensureSearchIndexBackfill()

            var matchedIDs = Set(try loadTransactionIDs(searchableNeedle: foldedNeedle))
            // WP19×WP38: Tag-Intersect in der Such-Kombi.
            if let taggedSet {
                matchedIDs = matchedIDs.intersection(taggedSet)
            }

            // WP10 (§76-79): GLOBALE Sortierung vor der Seitenauswahl,
            // Light-Rows (id + sort keys) der GESAMTEN Treffermenge laden,
            // global sortieren, dann die Seite exakt hydratisieren. Der alte
            // Pfad stoppte bei offset+limit über zufällig früh bearbeitete
            // ID-Chunks: Seite 1 war nicht die global neueste.
            var keys: [(id: UUID, date: Date, createdAt: Date)] = []
            keys.reserveCapacity(matchedIDs.count)
            let idArray = Array(matchedIDs)
            let chunkSize = 400
            var index = 0
            while index < idArray.count {
                let chunk = Set(idArray[index..<min(index + chunkSize, idArray.count)])
                var chunkDescriptor = descriptor
                chunkDescriptor.propertiesToFetch = [
                    \.id, \.effectiveDateValue, \.createdAt,
                    \.categoryID, \.accountID, \.sourceRaw
                ]
                let ids = chunk
                let startCopy = start
                let endCopy = end
                chunkDescriptor.predicate = #Predicate { entity in
                    ids.contains(entity.id)
                        && (entity.effectiveDateValue ?? entity.createdAt) >= startCopy
                        && (entity.effectiveDateValue ?? entity.createdAt) < endCopy
                }
                for row in try modelContext.fetch(chunkDescriptor) {
                    guard matchesAccountAndSource(row) else { continue }
                    // WP8 (§65): Category-Filter (In-Memory, SQL-sicher).
                    if matchesCategory(row) {
                        keys.append((
                            row.id,
                            row.effectiveDateValue ?? row.createdAt,
                            row.createdAt
                        ))
                    }
                }
                index += chunkSize
            }

            if ascending {
                keys.sort { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
            } else {
                // Gleiche Tie-Break-Regel wie die DB-Sortierung (siehe oben).
                keys.sort { $0.date != $1.date ? $0.date > $1.date : $0.createdAt < $1.createdAt }
            }

            let hasMore = keys.count > offset + limit
            let pageKeys = Array(keys.dropFirst(offset).prefix(limit))
            let pageIDs = Set(pageKeys.map(\.id))

            guard !pageIDs.isEmpty else {
                return TransactionPage(transactions: [], hasMore: false)
            }

            var pageDescriptor = descriptor
            let ids = pageIDs
            pageDescriptor.predicate = #Predicate { entity in
                ids.contains(entity.id)
            }
            pageDescriptor.fetchOffset = 0
            pageDescriptor.fetchLimit = limit
            let rows = try modelContext.fetch(pageDescriptor)
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let ordered = pageKeys.compactMap { key in byID[key.id] }
            let mapped = try ordered.map { try $0.toDomain() }
            return TransactionPage(transactions: mapped, hasMore: hasMore)
        }

        // Split attribution replaces the parent's category; apply it before paging.
        if !catIDs.isEmpty || hasStatusFilter {
            var collected = try modelContext.fetch(descriptor).filter {
                matchesCategory($0) && matchesStatus($0)
            }

            if ascending {
                collected.sort {
                    ($0.effectiveDateValue ?? $0.createdAt, $0.createdAt)
                        < ($1.effectiveDateValue ?? $1.createdAt, $1.createdAt)
                }
            } else {
                // Wie die DB-Sortierung: Datum absteigend, bei gleichem Datum
                // Anlagezeit AUFSTEIGEND, sonst ändert ein Filter die
                // Reihenfolge innerhalb eines Tages.
                collected.sort {
                    let lhs = $0.effectiveDateValue ?? $0.createdAt
                    let rhs = $1.effectiveDateValue ?? $1.createdAt
                    return lhs != rhs ? lhs > rhs : $0.createdAt < $1.createdAt
                }
            }

            let pageRows = Array(collected.dropFirst(offset).prefix(limit))
            let hasMore = collected.count > offset + limit
            let mapped = try pageRows.map { try $0.toDomain() }
            return TransactionPage(transactions: mapped, hasMore: hasMore)
        }

        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit + 1

        let rows = try modelContext.fetch(descriptor)
        let hasMore = rows.count > limit
        let mapped = try rows.prefix(limit).map { try $0.toDomain() }
        return TransactionPage(
            transactions: Array(mapped),
            hasMore: hasMore
        )
    }


    // MARK: - WP20: Store-seitige Direct-ID-Lookups (fetchLimit 1)

    /// WP13/WP14 (§98/§103): Leichte Review-Projection, nur die Felder,
    /// die die Review-Semantik braucht, werden hydratisiert (kein
    /// Full-Domain-Load über 50k). Die Review-Semantik selbst bleibt im
    /// ReviewQueueBuilder zentralisiert.
    func loadReviewCandidateTransactions() throws -> [Transaction] {
        var descriptor = FetchDescriptor<SDTransactionEntity>()
        descriptor.propertiesToFetch = [
            \.id, \.accountID, \.sourceRaw, \.statusRaw, \.kindRaw,
            \.amountValue, \.amountCurrencyRaw,
            \.bookedAt, \.authorizedAt, \.effectiveDateValue,
            \.rawDescription, \.rawMerchantName, \.merchantID, \.merchantDisplayName,
            \.categoryID, \.reviewed, \.excludedFromAnalytics, \.createdAt, \.updatedAt
        ]
        descriptor.includePendingChanges = false

        return try modelContext.fetch(descriptor).compactMap { (row: SDTransactionEntity) -> Transaction? in
            // NUR die leicht geladenen Felder lesen: Zugriff auf andere
            // Properties würde die Row re-faulten und den Gewinn zunichte-
            // machen.
            guard let status = TransactionStatus(rawValue: row.statusRaw) else { return nil }
            let kind = row.kindRaw.flatMap { TransactionKind(rawValue: $0) } ?? .unknown
            let currency = CurrencyCode(row.amountCurrencyRaw)
            let amountValue = Decimal(string: row.amountValue) ?? 0
            let source = TransactionSource(rawValue: row.sourceRaw) ?? .manual
            return Transaction(
                id: row.id,
                accountID: row.accountID,
                source: source,
                status: status,
                kind: kind,
                amount: Money(amount: amountValue, currency: currency),
                bookedAt: row.bookedAt,
                authorizedAt: row.authorizedAt,
                rawDescription: row.rawDescription,
                rawMerchantName: row.rawMerchantName,
                merchantID: row.merchantID,
                merchantDisplayName: row.merchantDisplayName,
                categoryID: row.categoryID,
                reviewed: row.reviewed ?? false,
                excludedFromAnalytics: row.excludedFromAnalytics ?? false,
                createdAt: row.createdAt,
                updatedAt: row.updatedAt
            )
        }
    }

    func loadAccount(id: UUID) throws -> Account? {
        var descriptor = FetchDescriptor<SDAccountEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try applyingOpeningBalances(try modelContext.fetch(descriptor).map { $0.toDomain() }).first
    }

    /// V13-Sidecar zusammenführen: Anfangsbestand/Stichtag an die Konten
    /// hängen. Strikt (#23): korrupte Beträge werfen statt 0.
    private func applyingOpeningBalances(_ accounts: [Account]) throws -> [Account] {
        guard !accounts.isEmpty else { return accounts }
        let ids = accounts.map(\.id)
        let descriptor = FetchDescriptor<SDAccountOpeningBalanceEntity>(
            predicate: #Predicate { ids.contains($0.accountID) }
        )
        var byAccount: [UUID: SDAccountOpeningBalanceEntity] = [:]
        for row in try modelContext.fetch(descriptor) {
            byAccount[row.accountID] = row
        }
        return try accounts.map { account in
            guard let row = byAccount[account.id] else { return account }
            var updated = account
            updated.openingBalance = try row.decimalAmount()
            updated.openingBalanceDate = row.date
            return updated
        }
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
        return try applyingOpeningBalances(try modelContext.fetch(descriptor).map { $0.toDomain() }).first
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
            for row in backup.accounts {
                modelContext.insert(SDAccountEntity(from: row))
                if let opening = row.openingBalance {
                    modelContext.insert(SDAccountOpeningBalanceEntity(accountID: row.id, amount: opening, date: row.openingBalanceDate))
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
    private func syncDerivedTransactionIndexes(
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
                    ($0.transactionID, $0.toDomain())
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
    private func deleteDerivedTransactionIndexes(transactionIDs: Set<UUID>) throws {
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

    /// WP19: Einmal-Prozess-Gate für den Join-Row-Backfill.
    private var tagJoinBackfillDone = false


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
        // WP2 (§14): Der Suchindex ist abgeleitete Row-Struktur der
        // Transaktionen und wird mitgelöscht.
        try modelContext.delete(model: SDTransactionSearchEntity.self)
        try modelContext.delete(model: SDTransactionTagEntity.self)
        // V12: Gruppenanteile sind User-Sidecar zur Transaktion (Cascade).
        try modelContext.delete(model: SDSharedExpenseShareEntity.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func loadTransactionAnnotations(transactionIDs: Set<UUID>) throws -> [TransactionAnnotation] {
        if transactionIDs.isEmpty {
            return try modelContext
                .fetch(FetchDescriptor<SDTransactionAnnotationEntity>())
                .map { $0.toDomain() }
        }
        let descriptor = FetchDescriptor<SDTransactionAnnotationEntity>(
            predicate: #Predicate { transactionIDs.contains($0.transactionID) }
        )
        return try modelContext.fetch(descriptor).map { $0.toDomain() }
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
        return try applyingOpeningBalances(rows.map { $0.toDomain() })
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
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    /// V13-Sidecar: Anfangsbestand anlegen, aktualisieren oder entfernen.
    private func upsertOpeningBalance(for account: Account) throws {
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
            try deleteDerivedTransactionIndexes(transactionIDs: Set(rows.map(\.id)))
            try deleteSharedExpenseShareRows(transactionIDs: Set(rows.map(\.id)))
            for row in rows {
                modelContext.delete(row)
            }
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

    /// Löscht Buchungszeilen und alles, was nur mit ihnen Sinn ergibt:
    /// Suchindex, Tags, Anteile, Annotationen, Splits, Sammlungs-Overrides
    /// und Zuordnungen zu Zahlungsplänen. Speichert NICHT: der Aufrufer
    /// entscheidet über save/rollback.
    private func deleteTransactionRowsWithDependents(_ rows: [SDTransactionEntity]) throws {
        let transactionIDs = Set(rows.map(\.id))
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
            try deleteDerivedTransactionIndexes(transactionIDs: Set(rows.map(\.id)))
            try deleteSharedExpenseShareRows(transactionIDs: Set(rows.map(\.id)))
            for entity in rows {
                modelContext.delete(entity)
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func loadImportBatches() throws -> [ImportBatch] {
        let rows = try modelContext.fetch(FetchDescriptor<SDImportBatchEntity>())
        return rows.map { $0.toDomain() }
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

    /// Löscht eine Kategorie und weist ihre Transaktionen neu zu
    /// (Roadmap #50: keine orphaned categoryIDs).
    func deleteCategory(id: UUID, reassignTo newCategoryID: UUID?) throws {
        let txnDescriptor = FetchDescriptor<SDTransactionEntity>(
            predicate: #Predicate { $0.categoryID == id }
        )
        for txn in try modelContext.fetch(txnDescriptor) {
            txn.categoryID = newCategoryID
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

    func loadConnections() throws -> [Connection] {
        let rows = try modelContext.fetch(FetchDescriptor<SDConnectionEntity>())
        return rows.map { $0.toDomain() }
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

            let mutations: [ImportMutation]
            if let data = batchEntity.mutationsJSON,
               let decoded = try? JSONDecoder().decode([ImportMutation].self, from: data) {
                mutations = decoded
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
                    modelContext.delete(entity)
                case .updated:
                    guard let snapshot = mutation.previousSnapshot else { continue }
                    let restored = snapshot.restoring(id: mutation.transactionID)
                    entity.update(from: restored)
                    restoredTransactions.append(restored)
                }
            }

            try deleteDerivedTransactionIndexes(transactionIDs: insertedIDs)
            try deleteSharedExpenseShareRows(transactionIDs: insertedIDs)
            try syncDerivedTransactionIndexes(for: restoredTransactions)
            modelContext.delete(batchEntity)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

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
    private func deleteSharedExpenseShareRows(transactionIDs: Set<UUID>) throws {
        guard !transactionIDs.isEmpty else { return }
        let descriptor = FetchDescriptor<SDSharedExpenseShareEntity>(
            predicate: #Predicate { transactionIDs.contains($0.transactionID) }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
    }
}
