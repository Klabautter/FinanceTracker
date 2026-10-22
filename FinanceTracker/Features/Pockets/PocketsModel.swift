import Foundation

@MainActor
@Observable
final class PocketsModel {
    private let dependencies: AppDependencies
    private let loadCollection: LoadTransactionCollection
    private let membershipResolver = TransactionCollectionResolver()
    private let effectiveResolver = EffectiveTransactionResolver()

    private(set) var items: [PocketListItem] = []
    private(set) var accounts: [Account] = []
    private(set) var categories: [Category] = []
    private(set) var excludedTransactionsByCollectionID: [UUID: [Transaction]] = [:]
    private(set) var overridesByCollectionID: [UUID: [TransactionCollectionOverride]] = [:]
    private(set) var candidateRows: [PocketTransactionRow] = []
    private(set) var isLoading = false
    private(set) var isLoadingCandidates = false
    private(set) var isSaving = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private var candidateLoadID: UUID?
    private var accountNamesByID: [UUID: String] = [:]
    private var categoryNamesByID: [UUID: String] = [:]
    private var overrideMapsByCollectionID: [UUID: [UUID: TransactionCollectionOverride]] = [:]

    var selectedCollectionID: UUID?
    var dataRevision: Int { dependencies.changeTracker.revision }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        loadCollection = LoadTransactionCollection(
            collectionRepository: dependencies.transactionCollectionRepository,
            overrideRepository: dependencies.transactionCollectionOverrideRepository,
            transactionRepository: dependencies.transactionRepository,
            annotationRepository: dependencies.transactionAnnotationRepository
        )
    }

    var activeAccounts: [Account] {
        accounts.filter(\.isActive)
    }

    var selectedItem: PocketListItem? {
        guard let selectedCollectionID else { return nil }
        return items.first { $0.id == selectedCollectionID }
    }

    var selectedRows: [PocketTransactionRow] {
        guard let selectedItem else { return [] }
        let overrides = overrideMap(for: selectedItem.id)
        return selectedItem.snapshot.transactions.map {
            row(for: $0, decision: overrides[$0.id]?.decision)
        }
    }

    var selectedExcludedRows: [PocketTransactionRow] {
        guard let selectedCollectionID else { return [] }
        let overrides = overrideMap(for: selectedCollectionID)
        return (excludedTransactionsByCollectionID[selectedCollectionID] ?? []).map {
            row(for: $0, decision: overrides[$0.id]?.decision)
        }
    }

    func items(status: PocketStatus) -> [PocketListItem] {
        items.filter { $0.status == status }
    }

    func load(now: Date = Date()) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let collectionsTask = dependencies.transactionCollectionRepository.collections()
            async let accountsTask = dependencies.accountRepository.accounts()
            async let categoriesTask = dependencies.categoryRepository.categories()
            async let overridesTask = dependencies.transactionCollectionOverrideRepository.allOverrides()

            let collections = try await collectionsTask
            accounts = try await accountsTask
            categories = try await categoriesTask
            let overrides = try await overridesTask
            accountNamesByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
            categoryNamesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })

            let snapshots = try await loadCollection.snapshots(
                collections: collections,
                overrides: overrides
            )
            items = sortedItems(snapshots.map {
                PocketListItem(
                    snapshot: $0,
                    status: PocketStatus.status(
                        startDate: $0.collection.startDate,
                        endDateExclusive: $0.collection.endDateExclusive,
                        now: now
                    )
                )
            })
            overridesByCollectionID = Dictionary(grouping: overrides, by: \.collectionID)
            overrideMapsByCollectionID = overridesByCollectionID.mapValues(Self.makeOverrideMap)
            try await loadExcludedTransactions(from: overrides)

            if selectedCollectionID == nil || !items.contains(where: { $0.id == selectedCollectionID }) {
                selectedCollectionID = items.first?.id
            }
        } catch {
            errorMessage = String(localized: "Sammlungen konnten nicht geladen werden.")
        }
    }

    func save(
        input: PocketEditorInput,
        replacing existing: TransactionCollection?
    ) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let collection = try input.collection(
                replacing: existing,
                activeAccountIDs: Set(activeAccounts.map(\.id))
            )
            try await dependencies.transactionCollectionRepository.upsert([collection])
            dependencies.changeTracker.markChanged()
            selectedCollectionID = collection.id
            let overrides = try await dependencies.transactionCollectionOverrideRepository
                .overrides(collectionID: collection.id)
            try await refresh(collection: collection, overrides: overrides)
            return true
        } catch let error as PocketEditorValidationError {
            errorMessage = error.message
            return false
        } catch {
            errorMessage = String(localized: "Sammlung konnte nicht gespeichert werden.")
            return false
        }
    }

    func delete(_ collection: TransactionCollection) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }

        do {
            try await dependencies.transactionCollectionRepository.delete(id: collection.id)
            dependencies.changeTracker.markChanged()
            if selectedCollectionID == collection.id { selectedCollectionID = nil }
            items.removeAll { $0.id == collection.id }
            overridesByCollectionID[collection.id] = nil
            overrideMapsByCollectionID[collection.id] = nil
            excludedTransactionsByCollectionID[collection.id] = nil
            if selectedCollectionID == nil {
                selectedCollectionID = items.first?.id
            }
        } catch {
            errorMessage = String(localized: "Sammlung konnte nicht gelöscht werden.")
        }
    }

    func exclude(_ transaction: Transaction) async {
        guard let collectionID = selectedCollectionID else { return }
        await setOverride(collectionID: collectionID, transaction: transaction, decision: .exclude)
    }

    func include(_ transaction: Transaction) async {
        guard let collectionID = selectedCollectionID else { return }
        await setOverride(collectionID: collectionID, transaction: transaction, decision: .include)
    }

    func restoreAutomation(for transaction: Transaction) async {
        guard let collectionID = selectedCollectionID,
              let collection = selectedItem?.collection,
              !isMutating else { return }
        isMutating = true
        defer { isMutating = false }

        do {
            try await dependencies.transactionCollectionOverrideRepository.delete(
                collectionID: collectionID,
                transactionID: transaction.id
            )
            dependencies.changeTracker.markChanged()
            let overrides = (overridesByCollectionID[collectionID] ?? []).filter {
                $0.transactionID != transaction.id
            }
            try await refresh(collection: collection, overrides: overrides)
        } catch {
            errorMessage = String(localized: "Die automatische Zuordnung konnte nicht wiederhergestellt werden.")
        }
    }

    func loadCandidates(searchText: String = "", accountID: UUID? = nil) async {
        guard let collection = selectedItem?.collection else { return }
        let loadID = UUID()
        candidateLoadID = loadID
        isLoadingCandidates = true
        candidateRows = []

        do {
            let queries = candidateQueries(
                for: collection,
                searchText: searchText,
                accountID: accountID
            )
            let raw = try await withThrowingTaskGroup(of: TransactionPage.self) { group in
                for query in queries {
                    group.addTask { [repository = dependencies.transactionRepository] in
                        try await repository.transactionPage(
                            matching: query,
                            sort: .dateDescending,
                            offset: 0,
                            limit: 300
                        )
                    }
                }
                var unique: [UUID: Transaction] = [:]
                for try await page in group {
                    for transaction in page.transactions {
                        unique[transaction.id] = transaction
                    }
                }
                return Array(unique.values)
            }
            let annotations = try await dependencies.transactionAnnotationRepository.annotations(
                transactionIDs: Set(raw.map(\.id))
            )
            guard candidateLoadID == loadID, !Task.isCancelled else { return }
            let effective = effectiveResolver.applying(annotations: annotations, to: raw)
            let overrides = overrideMap(for: collection.id)
            candidateRows = effective
                .filter { transaction in
                    !membershipResolver.contains(transaction, in: collection)
                        && overrides[transaction.id]?.decision != .include
                }
                .map { row(for: $0, decision: overrides[$0.id]?.decision) }
                .sorted { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }
            if candidateRows.count > 300 {
                candidateRows.removeLast(candidateRows.count - 300)
            }
        } catch {
            if candidateLoadID == loadID, !Task.isCancelled {
                errorMessage = String(localized: "Verfügbare Transaktionen konnten nicht geladen werden.")
            }
        }
        if candidateLoadID == loadID {
            isLoadingCandidates = false
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func setOverride(
        collectionID: UUID,
        transaction: Transaction,
        decision: TransactionCollectionOverrideDecision
    ) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }

        do {
            guard let collection = items.first(where: { $0.id == collectionID })?.collection else { return }
            let existing = overrideMap(for: collectionID)[transaction.id]
            let now = Date()
            let override = TransactionCollectionOverride(
                collectionID: collectionID,
                transactionID: transaction.id,
                decision: decision,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            try await dependencies.transactionCollectionOverrideRepository.upsert([override])
            dependencies.changeTracker.markChanged()
            var overrides = (overridesByCollectionID[collectionID] ?? []).filter {
                $0.transactionID != transaction.id
            }
            overrides.append(override)
            try await refresh(collection: collection, overrides: overrides)
        } catch {
            errorMessage = decision == .include
                ? String(localized: "Transaktion konnte nicht hinzugefügt werden.")
                : String(localized: "Transaktion konnte nicht ausgeschlossen werden.")
        }
    }

    private func loadExcludedTransactions(
        from overrides: [TransactionCollectionOverride]
    ) async throws {
        let excluded = overrides.filter { $0.decision == .exclude }
        let transactionIDs = Set(excluded.map(\.transactionID))
        guard !transactionIDs.isEmpty else {
            excludedTransactionsByCollectionID = [:]
            return
        }

        let raw = try await dependencies.transactionRepository.transactions(ids: transactionIDs)
        let annotations = try await dependencies.transactionAnnotationRepository.annotations(
            transactionIDs: transactionIDs
        )
        let effective = effectiveResolver.applying(annotations: annotations, to: raw)
        let transactionsByID = Dictionary(uniqueKeysWithValues: effective.map { ($0.id, $0) })
        var grouped: [UUID: [Transaction]] = [:]
        for override in excluded {
            if let transaction = transactionsByID[override.transactionID] {
                grouped[override.collectionID, default: []].append(transaction)
            }
        }
        excludedTransactionsByCollectionID = grouped.mapValues {
            $0.sorted { ($0.displayDate, $0.id.uuidString) > ($1.displayDate, $1.id.uuidString) }
        }
    }

    /// Zerlegt „außerhalb der Sammlung“ in disjunkte, indexierbare Queries:
    /// andere Konten sowie Zeiträume vor und nach dem Collection-Fenster.
    /// Dadurch kann der persistente Paging-/Suchindex vor der Hydratation auf
    /// höchstens 300 Zeilen pro Teilmenge begrenzen.
    private func candidateQueries(
        for collection: TransactionCollection,
        searchText: String,
        accountID: UUID?
    ) -> [TransactionQuery] {
        let requestedAccountIDs = accountID.map { Set([$0]) } ?? Set(accounts.map(\.id))
        let automaticAccountIDs = requestedAccountIDs.intersection(collection.accountIDs)
        let outsideAccountIDs = requestedAccountIDs.subtracting(collection.accountIDs)
        var queries: [TransactionQuery] = []

        if !outsideAccountIDs.isEmpty {
            var query = TransactionQuery()
            query.accountIDs = outsideAccountIDs
            query.searchText = searchText
            queries.append(query)
        }
        if !automaticAccountIDs.isEmpty {
            var before = TransactionQuery()
            before.accountIDs = automaticAccountIDs
            before.dateInterval = DateInterval(
                start: .distantPast,
                end: collection.startDate
            )
            before.searchText = searchText
            queries.append(before)

            var after = TransactionQuery()
            after.accountIDs = automaticAccountIDs
            after.dateInterval = DateInterval(
                start: collection.endDateExclusive,
                end: .distantFuture
            )
            after.searchText = searchText
            queries.append(after)
        }
        return queries
    }

    private func refresh(
        collection: TransactionCollection,
        overrides: [TransactionCollectionOverride],
        now: Date = Date()
    ) async throws {
        guard let snapshot = try await loadCollection.snapshots(
            collections: [collection],
            overrides: overrides
        ).first else { return }

        let item = PocketListItem(
            snapshot: snapshot,
            status: PocketStatus.status(
                startDate: collection.startDate,
                endDateExclusive: collection.endDateExclusive,
                now: now
            )
        )
        if let index = items.firstIndex(where: { $0.id == collection.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        items = sortedItems(items)
        overridesByCollectionID[collection.id] = overrides
        overrideMapsByCollectionID[collection.id] = Self.makeOverrideMap(overrides)
        try await loadExcludedTransactions(collectionID: collection.id, overrides: overrides)
    }

    private func loadExcludedTransactions(
        collectionID: UUID,
        overrides: [TransactionCollectionOverride]
    ) async throws {
        let transactionIDs = Set(
            overrides.lazy
                .filter { $0.decision == .exclude }
                .map(\.transactionID)
        )
        guard !transactionIDs.isEmpty else {
            excludedTransactionsByCollectionID[collectionID] = nil
            return
        }
        let raw = try await dependencies.transactionRepository.transactions(ids: transactionIDs)
        let annotations = try await dependencies.transactionAnnotationRepository.annotations(
            transactionIDs: transactionIDs
        )
        excludedTransactionsByCollectionID[collectionID] = effectiveResolver
            .applying(annotations: annotations, to: raw)
            .sorted { ($0.displayDate, $0.id.uuidString) > ($1.displayDate, $1.id.uuidString) }
    }

    private func sortedItems(_ values: [PocketListItem]) -> [PocketListItem] {
        values.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                return PocketStatus.allCases.firstIndex(of: lhs.status)!
                    < PocketStatus.allCases.firstIndex(of: rhs.status)!
            }
            return lhs.collection.startDate > rhs.collection.startDate
        }
    }

    private func overrideMap(for collectionID: UUID) -> [UUID: TransactionCollectionOverride] {
        overrideMapsByCollectionID[collectionID] ?? [:]
    }

    private static func makeOverrideMap(
        _ overrides: [TransactionCollectionOverride]
    ) -> [UUID: TransactionCollectionOverride] {
        Dictionary(
            overrides.map { ($0.transactionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func row(
        for transaction: Transaction,
        decision: TransactionCollectionOverrideDecision?
    ) -> PocketTransactionRow {
        PocketTransactionRow(
            transaction: transaction,
            accountName: accountNamesByID[transaction.accountID] ?? String(localized: "Unbekanntes Konto"),
            categoryName: transaction.categoryID.flatMap { categoryNamesByID[$0] } ?? String(localized: "Ohne Kategorie"),
            overrideDecision: decision
        )
    }
}
