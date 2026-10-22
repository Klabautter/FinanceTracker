import Foundation

enum LoadTransactionCollectionError: Error, Equatable, Sendable {
    case collectionNotFound(UUID)
}

struct LoadTransactionCollection: Sendable {
    let collectionRepository: any TransactionCollectionRepository
    let overrideRepository: any TransactionCollectionOverrideRepository
    let transactionRepository: any TransactionRepository
    let annotationRepository: any TransactionAnnotationRepository

    private let membershipResolver = TransactionCollectionResolver()
    private let effectiveResolver = EffectiveTransactionResolver()
    private let summaryCalculator = TransactionCollectionSummaryCalculator()

    func callAsFunction(
        collectionID: UUID,
        sort: TransactionSortOrder = .dateDescending
    ) async throws -> TransactionCollectionSnapshot {
        guard let collection = try await collectionRepository.collection(id: collectionID) else {
            throw LoadTransactionCollectionError.collectionNotFound(collectionID)
        }

        let overrides = try await overrideRepository.overrides(collectionID: collectionID)
        guard let snapshot = try await snapshots(
            collections: [collection],
            overrides: overrides,
            sort: sort
        ).first else {
            throw LoadTransactionCollectionError.collectionNotFound(collectionID)
        }
        return snapshot
    }

    /// Lädt mehrere Töpfe über einen gemeinsamen Transaktions- und
    /// Annotationspfad. Der Zeit-/Konten-Superset wird genau einmal aus der
    /// Persistenz geholt; manuell eingeschlossene Buchungen werden ebenfalls
    /// in einem einzigen ID-Batch ergänzt.
    func snapshots(
        collections: [TransactionCollection],
        overrides: [TransactionCollectionOverride],
        sort: TransactionSortOrder = .dateDescending
    ) async throws -> [TransactionCollectionSnapshot] {
        guard !collections.isEmpty else { return [] }

        let start = collections.map(\.startDate).min() ?? .distantPast
        let end = collections.map(\.endDateExclusive).max() ?? .distantFuture
        let accountIDs = collections.reduce(into: Set<UUID>()) { result, collection in
            result.formUnion(collection.accountIDs)
        }
        let includeIDs = Set(overrides.lazy.filter { $0.decision == .include }.map(\.transactionID))
        let query = TransactionQuery(
            dateInterval: DateInterval(start: start, end: end),
            accountIDs: accountIDs
        )

        async let automaticTask = transactionRepository.transactions(matching: query)
        async let includedTask = transactionRepository.transactions(ids: includeIDs)
        let candidates = try await automaticTask + includedTask
        let unique = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let transactionIDs = Set(unique.keys)
        let annotations = try await annotationRepository.annotations(transactionIDs: transactionIDs)
        let effective = effectiveResolver.applying(annotations: annotations, to: Array(unique.values))
        let transactionsByID = Dictionary(uniqueKeysWithValues: effective.map { ($0.id, $0) })
        let transactionsByAccountID = Dictionary(grouping: effective, by: \.accountID)
        let overridesByCollectionID = Dictionary(grouping: overrides, by: \.collectionID)

        return collections.map { collection in
            let collectionOverrides = overridesByCollectionID[collection.id] ?? []
            let overridesByTransactionID = Dictionary(
                collectionOverrides.map { ($0.transactionID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var scoped = collection.accountIDs.flatMap { transactionsByAccountID[$0] ?? [] }
            scoped += collectionOverrides.compactMap { override in
                guard override.decision == .include else { return nil }
                return transactionsByID[override.transactionID]
            }
            let uniqueScoped = Dictionary(
                scoped.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let resolved = uniqueScoped.values.filter {
                membershipResolver.contains(
                    $0,
                    in: collection,
                    override: overridesByTransactionID[$0.id]
                )
            }
            let sorted = sortTransactions(Array(resolved), by: sort)
            return TransactionCollectionSnapshot(
                collection: collection,
                transactions: sorted,
                currencySummaries: summaryCalculator.summaries(for: sorted)
            )
        }
    }

    private func sortTransactions(
        _ transactions: [Transaction],
        by sort: TransactionSortOrder
    ) -> [Transaction] {
        transactions.sorted { lhs, rhs in
            switch sort {
            case .dateDescending:
                return (lhs.displayDate, lhs.id.uuidString) > (rhs.displayDate, rhs.id.uuidString)
            case .dateAscending:
                return (lhs.displayDate, lhs.id.uuidString) < (rhs.displayDate, rhs.id.uuidString)
            case .amountDescending:
                return (lhs.amount.currency.rawValue, lhs.amount.amount, lhs.id.uuidString)
                    > (rhs.amount.currency.rawValue, rhs.amount.amount, rhs.id.uuidString)
            case .amountAscending:
                return (lhs.amount.currency.rawValue, lhs.amount.amount, lhs.id.uuidString)
                    < (rhs.amount.currency.rawValue, rhs.amount.amount, rhs.id.uuidString)
            case .merchantAscending:
                let comparison = lhs.effectiveMerchantName.localizedCaseInsensitiveCompare(rhs.effectiveMerchantName)
                return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
            case .merchantDescending:
                let comparison = lhs.effectiveMerchantName.localizedCaseInsensitiveCompare(rhs.effectiveMerchantName)
                return comparison == .orderedSame ? lhs.id.uuidString > rhs.id.uuidString : comparison == .orderedDescending
            }
        }
    }
}
