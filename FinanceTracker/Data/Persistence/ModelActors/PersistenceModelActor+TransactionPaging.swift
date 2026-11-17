import Foundation
@preconcurrency import SwiftData

/// Teil von `PersistenceModelActor` (nach Thema aufgeteilt, Roadmap 7.3).
extension PersistenceModelActor {
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
            entity.effectiveDateValue != nil && entity.effectiveDateValue! >= start
                && entity.effectiveDateValue! < end
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
                        && entity.effectiveDateValue != nil && entity.effectiveDateValue! >= start
                        && entity.effectiveDateValue! < end
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
            let keys: [SortKey] = try lightRows.map { row in
                guard let amount = Decimal(string: row.amountValue) else {
                    throw PersistenceDecodingError.invalidAmount(field: "Transaction.amount", raw: row.amountValue)
                }
                return SortKey(
                    id: row.id,
                    merchant: (row.merchantDisplayName ?? row.rawMerchantName ?? "")
                        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil),
                    currency: row.amountCurrencyRaw,
                    amount: amount
                )
            }

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
                        && entity.effectiveDateValue != nil && entity.effectiveDateValue! >= startCopy
                        && entity.effectiveDateValue! < endCopy
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

    /// Frühester und spätester Anlagezeitpunkt (für das Aufteilen großer
    /// Abfragen auf mehrere Actors); `nil` ohne Buchungen.
    func transactionCreatedAtRange() throws -> ClosedRange<Date>? {
        var first = FetchDescriptor<SDTransactionEntity>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        first.fetchLimit = 1
        first.propertiesToFetch = [\.createdAt]
        var last = FetchDescriptor<SDTransactionEntity>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        last.fetchLimit = 1
        last.propertiesToFetch = [\.createdAt]
        guard let lower = try modelContext.fetch(first).first?.createdAt,
              let upper = try modelContext.fetch(last).first?.createdAt else { return nil }
        return lower...upper
    }

    /// Wie `loadReviewCandidateTransactions()`, aber nur Zeilen mit
    /// `createdAt` in `[from, until)`: ein Teil einer parallelen Abfrage.
    func loadReviewCandidateTransactions(createdFrom from: Date, until: Date) throws -> [Transaction] {
        try loadReviewCandidateTransactions(predicate: #Predicate { $0.createdAt >= from && $0.createdAt < until })
    }

    /// WP13/WP14 (§98/§103): Leichte Review-Projection, nur die Felder,
    /// die die Review-Semantik braucht, werden hydratisiert (kein
    /// Full-Domain-Load über 50k). Die Review-Semantik selbst bleibt im
    /// ReviewQueueBuilder zentralisiert.
    func loadReviewCandidateTransactions() throws -> [Transaction] {
        try loadReviewCandidateTransactions(predicate: nil)
    }

    private func loadReviewCandidateTransactions(predicate: Predicate<SDTransactionEntity>?) throws -> [Transaction] {
        var descriptor = FetchDescriptor<SDTransactionEntity>(predicate: predicate)
        descriptor.propertiesToFetch = [
            \.id, \.accountID, \.sourceRaw, \.statusRaw, \.kindRaw,
            \.amountValue, \.amountCurrencyRaw,
            \.bookedAt, \.authorizedAt, \.effectiveDateValue,
            \.rawDescription, \.rawMerchantName, \.merchantID, \.merchantDisplayName,
            \.categoryID, \.reviewed, \.excludedFromAnalytics, \.createdAt, \.updatedAt
        ]
        descriptor.includePendingChanges = false

        return try modelContext.fetch(descriptor).map { (row: SDTransactionEntity) throws -> Transaction in
            // NUR die leicht geladenen Felder lesen: Zugriff auf andere
            // Properties würde die Row re-faulten und den Gewinn zunichte-
            // machen. Unlesbare Werte werfen wie im vollen Mapping (§23).
            guard let status = TransactionStatus(rawValue: row.statusRaw) else {
                throw PersistenceDecodingError.unknownStatus(raw: row.statusRaw)
            }
            let kind = row.kindRaw.flatMap { TransactionKind(rawValue: $0) } ?? .unknown
            let currency = CurrencyCode(row.amountCurrencyRaw)
            guard let amountValue = Decimal(string: row.amountValue) else {
                throw PersistenceDecodingError.invalidAmount(field: "Transaction.amount", raw: row.amountValue)
            }
            guard let source = TransactionSource(rawValue: row.sourceRaw) else {
                throw PersistenceDecodingError.unknownSource(raw: row.sourceRaw)
            }
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
}
