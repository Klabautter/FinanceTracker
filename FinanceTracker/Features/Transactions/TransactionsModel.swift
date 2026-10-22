import Foundation

enum TagFilterMode: String, CaseIterable, Identifiable {
    case any
    case all

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .any: String(localized: "Eines der Tags")
        case .all: String(localized: "Alle Tags")
        }
    }
}

@MainActor
@Observable
final class TransactionsModel {
    let dependencies: AppDependencies
    private let effectiveTransactionResolver = EffectiveTransactionResolver()

    private(set) var transactions: [Transaction] = []
    private(set) var categories: [Category] = []
    private(set) var categoriesByID: [UUID: Category] = [:]
    private(set) var accountsByID: [UUID: Account] = [:] {
        didSet { accountLabelsByID = Self.accountLabels(for: accountsByID) }
    }
    /// Anzeigename je Konto; gleichnamige Konten erhalten ihre Kennung als
    /// Zusatz, damit sie in der Tabelle unterscheidbar bleiben.
    private(set) var accountLabelsByID: [UUID: String] = [:]

    static func accountLabels(for accounts: [UUID: Account]) -> [UUID: String] {
        let nameCounts = Dictionary(grouping: accounts.values, by: \.name).mapValues(\.count)
        return accounts.mapValues { account in
            (nameCounts[account.name] ?? 0) > 1
                ? "\(account.name) · \(account.presentationIdentifier.replacingOccurrences(of: String(localized: "Referenz") + " ", with: ""))"
                : account.name
        }
    }
    private(set) var isLoading = false
    private(set) var isLoadingPage = false
    private(set) var errorMessage: String?
    private(set) var canLoadMore = false

    var searchText: String = ""
    var selectedSort: TransactionSortOrder = .dateDescending {
        didSet {
            if oldValue != selectedSort {
                syncTableFromSort()
            }
        }
    }
    var tableSortOrder: [KeyPathComparator<Transaction>] = [
        KeyPathComparator(\.displayDate, order: .reverse)
    ]
    var filterCategoryID: UUID?
    var filterTagIDs: Set<UUID> = []
    /// Konto-, Zeitraum- und Statusfilter laufen wie Kategorie und Tags als
    /// Query-Pushdown, sie gelten für alle Buchungen, nicht nur für die
    /// bereits geladenen Seiten. Eine Änderung lädt die Liste neu.
    var filterAccountID: UUID? {
        didSet { if oldValue != filterAccountID { reloadAfterFilterChange() } }
    }
    var filterStatus: TransactionStatus? {
        didSet { if oldValue != filterStatus { reloadAfterFilterChange() } }
    }
    var filterPeriod: TransactionPeriodFilter = .all {
        didSet { if oldValue != filterPeriod { reloadAfterFilterChange() } }
    }
    /// Grenzen für `filterPeriod == .custom` (beide Tage inklusive).
    var filterCustomStart: Date = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: Date())
    ) ?? Date() {
        didSet { if oldValue != filterCustomStart, filterPeriod == .custom { reloadAfterFilterChange() } }
    }
    var filterCustomEnd: Date = Date() {
        didSet { if oldValue != filterCustomEnd, filterPeriod == .custom { reloadAfterFilterChange() } }
    }

    /// Wirksames Zeitintervall des Zeitraumfilters (`nil` = keine Grenze).
    var filterPeriodInterval: DateInterval? {
        if filterPeriod == .custom {
            return TransactionPeriodFilter.customInterval(
                from: filterCustomStart, through: filterCustomEnd, calendar: .current
            )
        }
        return filterPeriod.interval(now: Date(), calendar: .current)
    }

    /// Unterdrückt das Neuladen, solange mehrere Filter am Stück gesetzt werden.
    private var suppressesFilterReload = false

    /// Laufendes Neuladen nach einer Filteränderung (abwartbar, u. a. für Tests).
    private(set) var filterReloadTask: Task<Void, Never>?

    private func reloadAfterFilterChange() {
        guard !suppressesFilterReload else { return }
        filterReloadTask = filterChanged()
    }

    /// Konten für das Filtermenü, mit unterscheidbaren Namen.
    var filterableAccounts: [(id: UUID, label: String)] {
        accountLabelsByID
            .map { (id: $0.key, label: $0.value) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Anzahl aktiver Listenfilter (ohne Suche und Sortierung).
    var activeFilterCount: Int {
        (filterCategoryID == nil ? 0 : 1)
            + filterTagIDs.count
            + (filterAccountID == nil ? 0 : 1)
            + (filterStatus == nil ? 0 : 1)
            + (filterPeriod == .all ? 0 : 1)
    }

    /// Setzt alle Listenfilter zurück und lädt genau einmal neu.
    func resetFilters() {
        suppressesFilterReload = true
        filterCategoryID = nil
        filterTagIDs = []
        filterAccountID = nil
        filterStatus = nil
        filterPeriod = .all
        suppressesFilterReload = false
        filterReloadTask = filterChanged()
    }
    /// Roadmap #16: ANY (eines der Tags) oder ALL (alle Tags).
    var tagFilterMode: TagFilterMode = .any
    private(set) var allTags: [Tag] = []
    /// MacUX-Audit (Cashflow-Drilldown): Monatsfilter aus dem Dashboard,
    /// fließt als dateInterval in den serverseitigen Query-Pushdown.
    private(set) var inheritedAnalyticsScope: AnalyticsScope?
    var monthFilter: DateInterval?

    var visibleTransactions: [Transaction] {
        guard !filterTagIDs.isEmpty else { return transactions }
        return transactions.filter { txn in
            let txnTags = Set(txn.tagIDs ?? [])
            switch tagFilterMode {
            case .any: return !txnTags.isDisjoint(with: filterTagIDs)
            case .all: return filterTagIDs.isSubset(of: txnTags)
            }
        }
    }
    private(set) var tagFilterLoading = false

    private var searchDebounceTask: Task<Void, Never>?
    private var loadGeneration = 0
    private let pageSize = 300

    /// MacUX-Perf: Revision des letzten von DIESEM Model verursachten
    /// Changes. Eigene Edits (Kategorie, Prüfstatus, Tags, Undo …) sind
    /// bereits in-memory aktualisiert, der Screen darf dafür keinen
    /// Full-Refetch mehr anstoßen (vorher: DB-Roundtrip + Tabellen-Reset
    /// pro Checkbox-Klick).
    private(set) var lastLocalRevision = 0
    /// MacUX-Perf: Erste Ladung erzwingen, danach entscheidet die
    /// Revision-Differenz (View: `.task(id: model.dataRevision)`).
    private(set) var hasLoadedData = false

    private func markLocallyChanged() {
        dependencies.changeTracker.markChanged()
        lastLocalRevision = dependencies.changeTracker.revision
    }

    /// Ablageort der Beleg-Dateien; `nil` = Standardverzeichnis der App.
    private let attachmentsBaseDirectory: URL?

    /// UI-Zustand für manuelle Buchungen: Kontextmenü und Detailbereich
    /// setzen ihn, der Screen präsentiert Formular bzw. Rückfrage.
    var transactionPendingEdit: Transaction?

    /// Neue Kategorie direkt aus einer Kategorieauswahl anlegen; danach wird
    /// sie der Buchung bzw. der Auswahl zugeordnet.
    enum CategoryCreationTarget: Identifiable {
        case transaction(Transaction)
        case selection(Set<Transaction.ID>)

        var id: String {
            switch self {
            case .transaction(let transaction): "transaction-\(transaction.id)"
            case .selection(let ids): "selection-\(ids.map(\.uuidString).sorted().joined())"
            }
        }
    }

    var categoryCreationTarget: CategoryCreationTarget?

    func categoryCreated(_ category: Category, for target: CategoryCreationTarget) async {
        await reloadCategories()
        switch target {
        case .transaction(let transaction):
            let current = self.transaction(withID: transaction.id) ?? transaction
            await assignCategory(current, to: category.id, rememberMerchant: false)
        case .selection(let ids):
            await bulkChangeCategory(category.id, for: ids)
        }
    }

    func reloadCategories() async {
        guard let fetched = try? await dependencies.categoryRepository.categories() else { return }
        categories = fetched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        categoriesByID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
    }
    var transactionPendingDeletion: Transaction?

    init(dependencies: AppDependencies, attachmentsBaseDirectory: URL? = nil) {
        self.dependencies = dependencies
        self.attachmentsBaseDirectory = attachmentsBaseDirectory
        self.tableSortOrder = [KeyPathComparator(\.displayDate, order: .reverse)]
    }

    // MARK: - Data Loading

    func refresh() async {
        let signpost = PerfSignpost.signposter.beginInterval("TransactionsRefresh")
        defer { PerfSignpost.signposter.endInterval("TransactionsRefresh", signpost) }
        searchDebounceTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
                hasLoadedData = true
            }
        }

        do {
            async let pageTask = fetchPage(offset: 0)
            async let categoriesTask = dependencies.categoryRepository.categories()
            async let accountsTask = dependencies.accountRepository.accounts()
            async let tagsTask = dependencies.tagRepository.tags()

            let page = try await pageTask
            guard generation == loadGeneration else { return }

            transactions = try await resolveAnnotations(for: page.transactions)
            canLoadMore = page.hasMore

            let fetchedCategories = try await categoriesTask
            let fetchedAccounts = try await accountsTask
            allTags = (try await tagsTask).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            categories = fetchedCategories.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            categoriesByID = Dictionary(
                uniqueKeysWithValues: fetchedCategories.map { ($0.id, $0) }
            )
            accountsByID = Dictionary(
                uniqueKeysWithValues: fetchedAccounts.map { ($0.id, $0) }
            )
        } catch {
            errorMessage = String(localized: "Die Transaktionen konnten nicht geladen werden.")
        }
    }

    /// Lädt genau eine Transaktion samt Darstellungs-Metadaten. Detail-Sheets
    /// dürfen nicht erst eine komplette Seite laden und hoffen, dass die
    /// angeklickte Transaktion darin enthalten ist.
    func load(transactionID: Transaction.ID) async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoadedData = true
        }

        do {
            async let transactionTask = dependencies.transactionRepository.transaction(id: transactionID)
            async let categoriesTask = dependencies.categoryRepository.categories()
            async let accountsTask = dependencies.accountRepository.accounts()
            async let tagsTask = dependencies.tagRepository.tags()

            guard let transaction = try await transactionTask else {
                transactions = []
                errorMessage = String(localized: "Die Transaktion wurde nicht gefunden.")
                return
            }

            transactions = try await resolveAnnotations(for: [transaction])
            let fetchedCategories = try await categoriesTask
            let fetchedAccounts = try await accountsTask
            let fetchedTags = try await tagsTask

            categories = fetchedCategories.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            categoriesByID = Dictionary(uniqueKeysWithValues: fetchedCategories.map { ($0.id, $0) })
            accountsByID = Dictionary(uniqueKeysWithValues: fetchedAccounts.map { ($0.id, $0) })
            allTags = fetchedTags.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            canLoadMore = false
        } catch {
            transactions = []
            errorMessage = String(localized: "Die Transaktionsdetails konnten nicht geladen werden.")
        }
    }

    func loadMoreIfNeeded(for transaction: Transaction) async {
        guard canLoadMore,
              transaction.id == transactions.last?.id,
              !isLoading,
              !isLoadingPage else { return }
        await loadNextPage()
    }

    private func loadNextPage() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoadingPage = true
        defer {
            if generation == loadGeneration {
                isLoadingPage = false
            }
        }
        do {
            let page = try await fetchPage(offset: transactions.count)
            guard generation == loadGeneration else { return }
            canLoadMore = page.hasMore
            transactions.append(contentsOf: try await resolveAnnotations(for: page.transactions))
        } catch {
            errorMessage = String(localized: "Weitere Transaktionen konnten nicht geladen werden.")
        }
    }

    /// Lädt weitere Seiten nach, bis der Tag-Filter genug Treffer zeigt.
    ///
    /// WP9 (§73): Der Cap ist reiner UI-Komfort gegen Endlos-Nachladen,
    /// fachlich korrekt ist der Filter längst serverseitig: Jede Seite
    /// enthält nur echte Treffer, und über „Weitere laden" wird die
    /// VOLLSTÄNDIGE Treffermenge erreicht. Kein Treffer geht verloren.
    func loadMoreForTagFilter() async {
        guard !filterTagIDs.isEmpty, canLoadMore, !tagFilterLoading else { return }
        tagFilterLoading = true
        defer { tagFilterLoading = false }
        var safety = 0
        while canLoadMore, safety < 10 {
            await loadNextPage()
            safety += 1
            if visibleTransactions.count >= 200 { break }
        }
    }

    func searchTextChanged() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    @discardableResult
    func filterChanged() -> Task<Void, Never> {
        searchDebounceTask?.cancel()
        return Task { await self.refresh() }
    }

    /// MacUX-Audit: Monatsfilter setzen (Cashflow-Klick) und zurücknehmen.
    @discardableResult
    func setMonthFilter(_ interval: DateInterval?) -> Task<Void, Never>? {
        guard monthFilter != interval || inheritedAnalyticsScope != nil else { return nil }
        inheritedAnalyticsScope = nil
        monthFilter = interval
        // Ein Monats-Drilldown ersetzt den frei gewählten Zeitraum.
        suppressesFilterReload = true
        filterPeriod = .all
        suppressesFilterReload = false
        return filterChanged()
    }

    @discardableResult
    func setAnalyticsScope(_ scope: AnalyticsScope) -> Task<Void, Never> {
        inheritedAnalyticsScope = scope
        monthFilter = scope.query.dateInterval
        searchText = ""
        suppressesFilterReload = true
        filterCategoryID = nil
        filterTagIDs = []
        filterAccountID = nil
        filterStatus = nil
        filterPeriod = .all
        suppressesFilterReload = false
        return filterChanged()
    }

    var monthFilterTitle: String? {
        guard let monthFilter else { return nil }
        return AppDateFormatter.monthYear(monthFilter.start)
    }

    /// WP21: Spaltenkopf-Sortierung läuft als GLOBALE Store-Sortierung,
    /// die geladenen Seiten kommen bereits sortiert, lokale Nachsortierung
    /// entfällt (Sortierung bleibt über Pagination stabil).
    func resortInPlace() {
        Task { await applyTableSort() }
    }

    /// WP21: Awaitable Sortier-Pfad (View nutzt resortInPlace als Task).
    func applyTableSort() async {
        guard let first = tableSortOrder.first else { return }
        let newSort: TransactionSortOrder
        switch first.keyPath {
        case \.displayDate:
            newSort = first.order == .forward ? .dateAscending : .dateDescending
        case \.effectiveMerchantName:
            newSort = first.order == .forward ? .merchantAscending : .merchantDescending
        case \.amountSortValue:
            newSort = first.order == .forward ? .amountAscending : .amountDescending
        default:
            newSort = .dateDescending
        }
        guard newSort != selectedSort else { return }
        selectedSort = newSort
        await refresh()
    }

    /// WP21: Mobile-Picker-Sortierung in die Table-SortOrder spiegeln.
    func syncTableFromSort() {
        switch selectedSort {
        case .dateAscending: tableSortOrder = [KeyPathComparator(\.displayDate, order: .forward)]
        case .dateDescending: tableSortOrder = [KeyPathComparator(\.displayDate, order: .reverse)]
        case .amountAscending: tableSortOrder = [KeyPathComparator(\.amountSortValue, order: .forward)]
        case .amountDescending: tableSortOrder = [KeyPathComparator(\.amountSortValue, order: .reverse)]
        case .merchantAscending: tableSortOrder = [KeyPathComparator(\.effectiveMerchantName, order: .forward)]
        case .merchantDescending: tableSortOrder = [KeyPathComparator(\.effectiveMerchantName, order: .reverse)]
        }
    }

    private func fetchPage(offset: Int) async throws -> TransactionPage {
        let foldedNeedle = searchText
            .trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()

        return try await dependencies.transactionRepository.transactionPage(
            matching: queryForFetch(foldedNeedle: foldedNeedle),
            sort: selectedSort,
            offset: offset,
            limit: pageSize
        )
    }

    private func queryForFetch(foldedNeedle: String) -> TransactionQuery {
        var query = inheritedAnalyticsScope?.query ?? TransactionQuery()
        if let monthFilter {
            query.dateInterval = monthFilter
        }
        if !foldedNeedle.isEmpty {
            query.searchText = foldedNeedle
        }
        if let filterCategoryID {
            // WP12: Parent als FILTER ist erlaubt, expandiert auf alle
            // Descendants (inkl. der Kategorie selbst).
            query.categoryIDs = CategoryHierarchy().descendantIDs(of: filterCategoryID, in: categories)
        }
        // WP19/WP9: Tag-Filter (ANY und ALL) laufen als DB-Pushdown über die
        // Join-Rows, „Alle Tags" ist global korrekt, kein Best-Effort.
        query.tagIDs = filterTagIDs
        query.tagMatchMode = tagFilterMode == .any ? .any : .all
        if let filterAccountID {
            query.accountIDs = [filterAccountID]
        }
        if let filterStatus {
            query.statuses = [filterStatus]
        }
        // Der frei gewählte Zeitraum hat Vorrang vor einem Monats-Drilldown.
        if let period = filterPeriodInterval {
            query.dateInterval = period
        }
        return query
    }

    private func resolveAnnotations(for transactions: [Transaction]) async throws -> [Transaction] {
        let annotations = try await dependencies.transactionAnnotationRepository.annotations(
            transactionIDs: Set(transactions.map(\.id))
        )
        for annotation in annotations {
            manualKindOverrides[annotation.transactionID] = annotation.manualKindOverride
        }
        return effectiveTransactionResolver.applying(annotations: annotations, to: transactions)
    }

    /// Manuelle Typ-Overrides pro Transaktion (für Detail-UI „Zurücksetzen“).
    private(set) var manualKindOverrides: [Transaction.ID: TransactionKind] = [:]

    /// Undo/Redo-Baseline (Roadmap #26): eigener, deterministischer Stack
    /// (await-bar und unit-testbar; ⌘Z/⌘⇧Z werden über die View gebunden).
    private struct UndoStep {
        let name: String
        let revert: @MainActor () async -> Void
        let apply: @MainActor () async -> Void
    }

    private var undoStack: [UndoStep] = []
    private var redoStack: [UndoStep] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Namen für Menü-/A11y-Labels („Kategorie rückgängig machen“).
    /// Keine Business-Logik, nur Stack-Spitze.
    var undoActionName: String? { undoStack.last?.name }
    var redoActionName: String? { redoStack.last?.name }

    func undo() async {
        guard let step = undoStack.popLast() else { return }
        merchantCategoryOffer = nil
        await step.revert()
        redoStack.append(step)
    }

    func redo() async {
        guard let step = redoStack.popLast() else { return }
        await step.apply()
        undoStack.append(step)
    }

    private func pushUndo(
        name: String,
        revert: @escaping @MainActor () async -> Void,
        apply: @escaping @MainActor () async -> Void
    ) {
        undoStack.append(UndoStep(name: name, revert: revert, apply: apply))
        redoStack.removeAll()
    }

    private func persistAndResync(_ transaction: Transaction) async {
        do {
            try await dependencies.transactionRepository.upsert([transaction])
            if let index = transactions.firstIndex(where: { $0.id == transaction.id }) {
                let resolved = try await resolveAnnotations(for: [transaction])
                transactions[index] = resolved.first ?? transaction
            }
            markLocallyChanged()
        } catch {
            errorMessage = String(localized: "Änderung konnte nicht gespeichert werden.")
        }
    }

    func restoreTransaction(_ transaction: Transaction) async {
        do {
            try await dependencies.transactionRepository.upsert([transaction])
            if let index = transactions.firstIndex(where: { $0.id == transaction.id }) {
                transactions[index] = transaction
            }
            markLocallyChanged()
        } catch {
            errorMessage = String(localized: "Rückgängig konnte nicht angewendet werden.")
        }
    }

    /// Stellt Annotation (oder löscht sie) + Transaktionszeile wieder her.
    func restore(annotation: TransactionAnnotation?, transaction: Transaction) async {
        do {
            if let annotation {
                try await dependencies.transactionAnnotationRepository.upsert([annotation])
                manualKindOverrides[transaction.id] = annotation.manualKindOverride
            } else {
                try await dependencies.transactionAnnotationRepository.delete(transactionID: transaction.id)
                manualKindOverrides[transaction.id] = nil
            }
            try await dependencies.transactionRepository.upsert([transaction])
            if let index = transactions.firstIndex(where: { $0.id == transaction.id }) {
                let resolved = try await resolveAnnotations(for: [transaction])
                transactions[index] = resolved.first ?? transaction
            }
            markLocallyChanged()
        } catch {
            errorMessage = String(localized: "Rückgängig konnte nicht angewendet werden.")
        }
    }

    private func existingAnnotation(for transaction: Transaction) async throws -> TransactionAnnotation? {
        try await dependencies.transactionAnnotationRepository.annotation(transactionID: transaction.id)
    }

    private func annotation(for transaction: Transaction) async throws -> TransactionAnnotation {
        if let existing = try await existingAnnotation(for: transaction) {
            return existing
        }
        return TransactionAnnotation.legacyFallback(for: transaction)
    }

    // MARK: - Lookups

    func transaction(withID id: Transaction.ID) -> Transaction? {
        transactions.first { $0.id == id }
    }

    func category(for transaction: Transaction) -> Category? {
        guard let categoryID = transaction.categoryID else { return nil }
        return categoriesByID[categoryID]
    }

    func account(for transaction: Transaction) -> Account? {
        accountsByID[transaction.accountID]
    }

    var parentCategories: [Category] {
        categories.filter { $0.parentID == nil }
    }

    /// WP12: Nur Leaves sind zuweisbar (Parents = aggregation-only).
    /// Parents ohne Kinder gelten als wählbares Leaf.
    var assignableCategories: [Category] {
        CategoryHierarchy().assignableCategories(in: categories)
    }

    var dataRevision: Int { dependencies.changeTracker.revision }

    // MARK: - Single Transaction Actions

    func changeCategory(
        _ transaction: Transaction,
        to categoryID: UUID?,
        offersMerchantChange: Bool = true
    ) async {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        merchantCategoryOffer = nil
        let previousTransaction = transaction
        var updated = transaction
        updated.categoryID = categoryID
        updated.updatedAt = Date()
        transactions[index] = updated
        do {
            try await dependencies.transactionRepository.upsert([updated])
            markLocallyChanged()
        } catch {
            errorMessage = String(localized: "Die Kategorie konnte nicht gespeichert werden.")
            await refresh()
            return
        }
        pushUndo(
            name: String(localized: "Kategorie"),
            revert: { [weak self] in
                guard let self else { return }
                await self.restoreTransaction(previousTransaction)
            },
            apply: { [weak self] in
                guard let self else { return }
                await self.persistAndResync(updated)
            }
        )
        if offersMerchantChange {
            await prepareMerchantCategoryOffer(for: updated)
        }
    }

    // MARK: - Kategorie für alle Buchungen eines Händlers

    /// Rückfrage nach einer einzelnen Kategorie-Änderung: dieselbe Kategorie
    /// für die übrigen Buchungen des Händlers und für künftige übernehmen?
    struct MerchantCategoryOffer: Equatable {
        let transactionID: Transaction.ID
        let merchantName: String
        let categoryID: Category.ID
        let categoryName: String
        /// Weitere Buchungen dieses Händlers mit anderer oder ohne Kategorie.
        let otherCount: Int

        var message: String {
            switch otherCount {
            case 0: String(localized: "„\(merchantName)“ künftig immer als \(categoryName) zuordnen?")
            case 1: String(localized: "Auch die andere „\(merchantName)“-Buchung auf \(categoryName) ändern und künftig so zuordnen?")
            default: String(localized: "Auch die \(otherCount) anderen „\(merchantName)“-Buchungen auf \(categoryName) ändern und künftig so zuordnen?")
            }
        }
    }

    private(set) var merchantCategoryOffer: MerchantCategoryOffer?

    func dismissMerchantCategoryOffer() {
        merchantCategoryOffer = nil
    }

    /// Die Lernregel für den Händler dieser Buchung, dieselbe, die auch die
    /// Prüfliste anlegt. `nil`, wenn der Händler nicht erkennbar ist.
    private func merchantRule(for transaction: Transaction, categoryID: Category.ID) async throws
        -> (rule: CategoryRule, existing: CategoryRule?)? {
        let existingRules = try await dependencies.ruleRepository.rules()
        guard let rule = CategoryRule.makeFromCorrection(
            transaction: transaction,
            categoryID: categoryID,
            existingRules: existingRules
        ) else { return nil }
        return (rule, existingRules.first { $0.id == rule.id })
    }

    /// Alle übrigen Buchungen desselben Händlers (im ganzen Bestand, nicht
    /// nur in der geladenen Seite), deren Kategorie abweicht.
    private func merchantSiblings(
        of transaction: Transaction,
        matching rule: CategoryRule,
        categoryID: Category.ID
    ) async throws -> [Transaction] {
        let compiled = CategoryRuleEngine().compile([rule])
        return try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
            .filter { $0.id != transaction.id && $0.categoryID != categoryID && compiled.firstMatch(for: $0) != nil }
    }

    private func prepareMerchantCategoryOffer(for transaction: Transaction) async {
        merchantCategoryOffer = nil
        guard let categoryID = transaction.categoryID,
              let category = categoriesByID[categoryID],
              CategoryHierarchy().isAssignable(categoryID, in: categories),
              // Überweisungen an Personen sind jedes Mal etwas anderes.
              !PersonNameDetector.isPersonName(transaction.effectiveMerchantName) else { return }
        do {
            guard let (rule, existing) = try await merchantRule(for: transaction, categoryID: categoryID) else { return }
            let siblings = try await merchantSiblings(of: transaction, matching: rule, categoryID: categoryID)
            // Ohne weitere Buchungen lohnt die Frage nur, wenn eine
            // bestehende Händler-Regel sonst weiter falsch zuordnen würde.
            let contradictsRule = existing.map { $0.categoryID != categoryID && $0.enabled } ?? false
            guard !siblings.isEmpty || contradictsRule else { return }
            merchantCategoryOffer = MerchantCategoryOffer(
                transactionID: transaction.id,
                merchantName: transaction.effectiveMerchantName,
                categoryID: categoryID,
                categoryName: category.name,
                otherCount: siblings.count
            )
        } catch {
            // Die Einzeländerung ist gespeichert; die Rückfrage ist Zusatz.
        }
    }

    /// Übernimmt die Kategorie für alle Buchungen des Händlers und merkt sie
    /// für künftige. Ein Schritt im Verlauf: ⌘Z nimmt alles zurück.
    func applyMerchantCategoryOffer() async {
        guard let offer = merchantCategoryOffer,
              let transaction = transaction(withID: offer.transactionID) else {
            merchantCategoryOffer = nil
            return
        }
        merchantCategoryOffer = nil
        do {
            guard let (rule, previousRule) = try await merchantRule(for: transaction, categoryID: offer.categoryID) else { return }
            let originals = try await merchantSiblings(of: transaction, matching: rule, categoryID: offer.categoryID)
            let now = Date()
            let changed = originals.map { original -> Transaction in
                var updated = original
                updated.categoryID = offer.categoryID
                updated.updatedAt = now
                return updated
            }
            try await writeMerchantCategory(changed, rule: rule, deletingRuleID: nil)
            pushUndo(
                name: String(localized: "Kategorie für Händler"),
                revert: { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.writeMerchantCategory(
                            originals,
                            rule: previousRule,
                            deletingRuleID: previousRule == nil ? rule.id : nil
                        )
                    } catch {
                        self.errorMessage = String(localized: "Rückgängig konnte nicht angewendet werden.")
                    }
                },
                apply: { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.writeMerchantCategory(changed, rule: rule, deletingRuleID: nil)
                    } catch {
                        self.errorMessage = String(localized: "Änderung konnte nicht gespeichert werden.")
                    }
                }
            )
        } catch {
            errorMessage = String(localized: "Die Kategorie konnte nicht für alle Buchungen des Händlers übernommen werden.")
        }
    }

    /// Schreibt Buchungen und Händler-Regel und zieht die geladene Liste nach.
    private func writeMerchantCategory(
        _ transactionsToWrite: [Transaction],
        rule: CategoryRule?,
        deletingRuleID: UUID?
    ) async throws {
        if let rule {
            try await dependencies.ruleRepository.upsert([rule])
        }
        if let deletingRuleID {
            try await dependencies.ruleRepository.delete(id: deletingRuleID)
        }
        if !transactionsToWrite.isEmpty {
            try await dependencies.transactionRepository.upsert(transactionsToWrite)
        }
        let categoriesByTransactionID = Dictionary(
            transactionsToWrite.map { ($0.id, $0.categoryID) },
            uniquingKeysWith: { first, _ in first }
        )
        for index in transactions.indices {
            if let categoryID = categoriesByTransactionID[transactions[index].id] {
                transactions[index].categoryID = categoryID
            }
        }
        markLocallyChanged()
    }

    /// Produktstandard für manuelle Korrekturen: Die Auswahl gilt auf Wunsch
    /// direkt für denselben Händler. Dadurch werden künftige Importe und
    /// bereits unzugeordnete Treffer ohne zusätzliche Nacharbeit kategorisiert.
    func assignCategory(
        _ transaction: Transaction,
        to categoryID: UUID?,
        rememberMerchant: Bool
    ) async {
        // Mit „merken" entsteht die Rückfrage erst nach dem Lernen: Dann
        // zählt sie nur noch die Buchungen, die eine andere Kategorie haben.
        await changeCategory(transaction, to: categoryID, offersMerchantChange: !rememberMerchant)
        guard rememberMerchant,
              let categoryID,
              let updated = self.transaction(withID: transaction.id),
              updated.categoryID == categoryID else { return }
        do {
            try await learnMerchant(from: updated, categoryID: categoryID)
        } catch {
            // Die konkrete Korrektur ist bereits gespeichert. Nur das Lernen
            // ist fehlgeschlagen, daher die Ansicht nicht durch einen
            // Full-Screen-Fehler ersetzen.
            errorMessage = String(localized: "Die Kategorie wurde gesetzt, konnte für diesen Händler aber nicht gemerkt werden.")
        }
        await prepareMerchantCategoryOffer(for: updated)
    }

    /// Legt die Händler-Regel an und ordnet bislang unkategorisierte
    /// Buchungen des Händlers zu.
    private func learnMerchant(from updated: Transaction, categoryID: Category.ID) async throws {
        let existingRules = try await dependencies.ruleRepository.rules()
        guard let rule = CategoryRule.makeFromCorrection(
            transaction: updated,
            categoryID: categoryID,
            existingRules: existingRules
        ) else { return }

        if existingRules.first(where: { $0.id == rule.id }) != rule {
            try await dependencies.ruleRepository.upsert([rule])
        }
        let affectedIDs = try await dependencies.transactionRepository.assignCategoriesToUncategorized(
            matching: [rule],
            assignableCategoryIDs: [categoryID]
        )
        for index in transactions.indices where affectedIDs.contains(transactions[index].id) {
            transactions[index].categoryID = categoryID
            transactions[index].updatedAt = Date()
        }
        markLocallyChanged()
    }

    func createRule(from transaction: Transaction) async -> Bool {
        guard let categoryID = transaction.categoryID else { return false }
        guard CategoryHierarchy().isAssignable(categoryID, in: categories) else { return false }
        do {
            let existingRules = try await dependencies.ruleRepository.rules()
            guard let rule = CategoryRule.makeFromCorrection(
                transaction: transaction,
                categoryID: categoryID,
                existingRules: existingRules
            ) else { return false }
            if existingRules.first(where: { $0.id == rule.id }) != rule {
                try await dependencies.ruleRepository.upsert([rule])
                markLocallyChanged()
            }
            return true
        } catch {
            errorMessage = String(localized: "Die Regel konnte nicht gespeichert werden.")
            return false
        }
    }

    // MARK: - Annotation Actions

    func toggleReviewed(_ transaction: Transaction, reviewed: Bool) async {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        do {
            let previousAnnotation = try await existingAnnotation(for: transaction)
            var annotation = try await annotation(for: transaction)
            annotation.reviewed = reviewed
            annotation.updatedAt = Date()
            try await dependencies.transactionAnnotationRepository.upsert([annotation])
            pushUndo(
                name: String(localized: "Prüfstatus"),
                revert: { [weak self] in
                    guard let self else { return }
                    await self.restore(annotation: previousAnnotation, transaction: transaction)
                },
                apply: { [weak self] in
                    guard let self else { return }
                    await self.restore(annotation: annotation, transaction: transaction)
                }
            )
            transactions[index] = effectiveTransactionResolver.applying(annotation: annotation, to: transaction)
            markLocallyChanged()
        } catch {
            errorMessage = String(localized: "Der Prüfstatus konnte nicht gespeichert werden.")
            await refresh()
        }
    }

    func toggleExcluded(_ transaction: Transaction, excluded: Bool) async {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        do {
            let previousAnnotation = try await existingAnnotation(for: transaction)
            var annotation = try await annotation(for: transaction)
            annotation.excludedFromAnalytics = excluded
            annotation.updatedAt = Date()
            try await dependencies.transactionAnnotationRepository.upsert([annotation])
            pushUndo(
                name: String(localized: "Analyse-Ausschluss"),
                revert: { [weak self] in
                    guard let self else { return }
                    await self.restore(annotation: previousAnnotation, transaction: transaction)
                },
                apply: { [weak self] in
                    guard let self else { return }
                    await self.restore(annotation: annotation, transaction: transaction)
                }
            )
            transactions[index] = effectiveTransactionResolver.applying(annotation: annotation, to: transaction)
            markLocallyChanged()
        } catch {
            errorMessage = String(localized: "Der Analyse-Ausschluss konnte nicht gespeichert werden.")
            await refresh()
        }
    }

    func updateNote(_ transaction: Transaction, note: String?) async {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        do {
            let previousAnnotation = try await existingAnnotation(for: transaction)
            var annotation = try await annotation(for: transaction)
            annotation.note = note?.isEmpty == true ? nil : note
            annotation.updatedAt = Date()
            try await dependencies.transactionAnnotationRepository.upsert([annotation])
            pushUndo(
                name: String(localized: "Notiz"),
                revert: { [weak self] in
                    guard let self else { return }
                    await self.restore(annotation: previousAnnotation, transaction: transaction)
                },
                apply: { [weak self] in
                    guard let self else { return }
                    await self.restore(annotation: annotation, transaction: transaction)
                }
            )
            transactions[index] = effectiveTransactionResolver.applying(annotation: annotation, to: transaction)
            markLocallyChanged()
        } catch {
            errorMessage = String(localized: "Die Notiz konnte nicht gespeichert werden.")
            await refresh()
        }
    }

    /// Manual Kind Override (Roadmap #64): User-Entscheidung gewinnt über
    /// den Detector; nil entfernt den Override und stellt den ursprünglichen
    /// Typ aus der RAW-Transaktion wieder her (die Annotation speichert ihn
    /// bewusst nicht, der Provider-Fakt bleibt Quelle der Wahrheit).
    /// Aktive Bargeldkonten für „Bargeldabhebung gutschreiben".
    var cashAccounts: [Account] {
        accountsByID.values
            .filter { $0.type == .cash && $0.isActive }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Bankbuchung als Abhebung ins Bargeldkonto spiegeln (Transfer-Paar).
    /// Kein Undo-Eintrag: Die Gegenbuchung ist eine eigene manuelle Buchung,
    /// die sich im Bargeldkonto löschen lässt.
    func mirrorCashWithdrawal(_ transaction: Transaction, into cash: Account) async {
        do {
            let useCase = MirrorCashWithdrawal(dependencies: dependencies)
            let sourceName = accountsByID[transaction.accountID]?.name ?? String(localized: "Konto")
            switch try await useCase.mirror(transaction, into: cash, sourceAccountName: sourceName) {
            case .created:
                dependencies.changeTracker.markChanged()
                await refresh()
            case .alreadyMirrored:
                errorMessage = String(localized: "Diese Abhebung ist bereits im Bargeldkonto gutgeschrieben.")
            case .currencyMismatch:
                errorMessage = String(localized: "Bargeldkonto und Buchung haben unterschiedliche Währungen.")
            case .notEligible:
                errorMessage = String(localized: "Nur Ausgaben von einem anderen Konto lassen sich als Abhebung gutschreiben.")
            }
        } catch {
            errorMessage = String(localized: "Die Abhebung konnte nicht gutgeschrieben werden.")
        }
    }

    func setManualKind(_ kind: TransactionKind?, on transaction: Transaction) async {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        do {
            let previousAnnotation = try await existingAnnotation(for: transaction)
            let rawTransaction = try await dependencies.transactionRepository.transaction(id: transaction.id) ?? transaction
            var annotation = try await annotation(for: transaction)
            annotation.manualKindOverride = kind
            annotation.updatedAt = Date()
            try await dependencies.transactionAnnotationRepository.upsert([annotation])
            pushUndo(
                name: String(localized: "Typ"),
                revert: { [weak self] in
                    guard let self else { return }
                    await self.restore(annotation: previousAnnotation, transaction: transaction)
                },
                apply: { [weak self] in
                    guard let self else { return }
                    await self.restore(annotation: annotation, transaction: transaction)
                }
            )
            manualKindOverrides[transaction.id] = kind
            let base = kind == nil ? rawTransaction : transaction
            transactions[index] = effectiveTransactionResolver.applying(annotation: annotation, to: base)
            markLocallyChanged()
        } catch {
            errorMessage = String(localized: "Der Typ konnte nicht gespeichert werden.")
            await refresh()
        }
    }

    /// Setzt die Tag-Zuordnung einer Transaktion vollständig (Roadmap #15).
    func setTags(_ tagIDs: [UUID], on transaction: Transaction) async {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        do {
            let previousAnnotation = try await existingAnnotation(for: transaction)
            var annotation = try await annotation(for: transaction)
            annotation.tagIDs = tagIDs
            annotation.updatedAt = Date()
            try await dependencies.transactionAnnotationRepository.upsert([annotation])
            pushUndo(
                name: String(localized: "Tags"),
                revert: { [weak self] in
                    guard let self else { return }
                    await self.restore(annotation: previousAnnotation, transaction: transaction)
                },
                apply: { [weak self] in
                    guard let self else { return }
                    await self.restore(annotation: annotation, transaction: transaction)
                }
            )
            transactions[index] = effectiveTransactionResolver.applying(annotation: annotation, to: transaction)
            markLocallyChanged()
        } catch {
            errorMessage = String(localized: "Die Tags konnten nicht gespeichert werden.")
            await refresh()
        }
    }

    func toggleTag(_ tagID: UUID, on transaction: Transaction) async {
        var tagIDs = transaction.tagIDs ?? []
        if let existingIndex = tagIDs.firstIndex(of: tagID) {
            tagIDs.remove(at: existingIndex)
        } else {
            tagIDs.append(tagID)
        }
        await setTags(tagIDs, on: transaction)
    }

    // MARK: - Bulk Actions

    // MARK: - Manuelle Buchungen

    /// Nur selbst erfasste Buchungen sind lösch-/änderbar, Bank- und
    /// Importdaten bleiben Provider-Fakten.
    func canDeleteManually(_ transaction: Transaction) -> Bool {
        transaction.source == .manual
    }

    /// Transfer-Paare bestehen aus zwei gekoppelten Buchungen und lassen
    /// sich nur gemeinsam löschen, nicht einzeln umschreiben.
    func canEditManually(_ transaction: Transaction) -> Bool {
        transaction.source == .manual && transaction.kind != .transfer
    }

    /// externalID der Gegenbuchung eines manuellen Transfer-Paars.
    static func transferCounterpartExternalID(for transaction: Transaction) -> String? {
        guard transaction.source == .manual, let externalID = transaction.externalID else { return nil }
        if externalID.hasSuffix("-transfer:from") {
            return String(externalID.dropLast("from".count)) + "to"
        }
        if externalID.hasSuffix("-transfer:to") {
            return String(externalID.dropLast("to".count)) + "from"
        }
        return nil
    }

    func isTransferPairLeg(_ transaction: Transaction) -> Bool {
        Self.transferCounterpartExternalID(for: transaction) != nil
    }

    /// Löscht eine manuelle Buchung (bei Transfers beide Seiten) samt
    /// Belegen. Ohne Belege ist der Schritt per ⌘Z rückholbar.
    func deleteManualTransaction(_ transaction: Transaction) async {
        guard canDeleteManually(transaction) else { return }
        do {
            var ids: Set<UUID> = [transaction.id]
            if let counterpartID = Self.transferCounterpartExternalID(for: transaction) {
                let manual = try await dependencies.transactionRepository
                    .transactions(matching: TransactionQuery(sources: [.manual]))
                if let counterpart = manual.first(where: { $0.externalID == counterpartID }) {
                    ids.insert(counterpart.id)
                }
            }

            // Rohzeilen + Annotationen für Undo sichern, bevor etwas verschwindet.
            let rawTransactions = try await dependencies.transactionRepository.transactions(ids: ids)
            let annotations = try await dependencies.transactionAnnotationRepository.annotations(transactionIDs: ids)

            let removedAttachments = try await AttachmentCleanup.removeAttachments(
                of: ids,
                dependencies: dependencies,
                baseDirectory: attachmentsBaseDirectory
            )
            try await dependencies.transactionRepository.deleteTransactions(ids: ids)
            transactions.removeAll { ids.contains($0.id) }
            markLocallyChanged()

            // Beleg-Dateien sind endgültig weg, dann wäre ein Undo nur halb.
            guard removedAttachments == 0 else { return }
            pushUndo(
                name: String(localized: "Löschen"),
                revert: { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.dependencies.transactionRepository.upsert(rawTransactions)
                        if !annotations.isEmpty {
                            try await self.dependencies.transactionAnnotationRepository.upsert(annotations)
                        }
                        self.dependencies.changeTracker.markChanged()
                        await self.refresh()
                    } catch {
                        self.errorMessage = String(localized: "Rückgängig konnte nicht angewendet werden.")
                    }
                },
                apply: { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.dependencies.transactionRepository.deleteTransactions(ids: ids)
                        self.transactions.removeAll { ids.contains($0.id) }
                        self.markLocallyChanged()
                    } catch {
                        self.errorMessage = String(localized: "Die Buchung konnte nicht gelöscht werden.")
                    }
                }
            )
        } catch {
            errorMessage = String(localized: "Die Buchung konnte nicht gelöscht werden.")
        }
    }

    func bulkChangeCategory(_ categoryID: UUID?, for targetIDs: Set<Transaction.ID>) async {
        let targets = transactions.filter { targetIDs.contains($0.id) }
        var updates: [Transaction] = []
        for var txn in targets {
            txn.categoryID = categoryID
            txn.updatedAt = Date()
            updates.append(txn)
        }
        guard !updates.isEmpty else { return }
        do {
            try await dependencies.transactionRepository.upsert(updates)
            for update in updates {
                if let idx = transactions.firstIndex(where: { $0.id == update.id }) {
                    transactions[idx] = update
                }
            }
            markLocallyChanged()
            // Auch Sammel-Aktionen sind ein Undo-Schritt, sonst
            // nähme ⌘Z stillschweigend eine ältere, fremde Änderung zurück.
            pushUndo(
                name: String(localized: "Kategorie (\(updates.count))"),
                revert: { [weak self] in
                    guard let self else { return }
                    for previous in targets { await self.restoreTransaction(previous) }
                },
                apply: { [weak self] in
                    guard let self else { return }
                    for update in updates { await self.persistAndResync(update) }
                }
            )
        } catch {
            errorMessage = String(localized: "Bulk-Kategorie konnte nicht gespeichert werden.")
        }
    }

    func bulkToggleReviewed(_ reviewed: Bool, for targetIDs: Set<Transaction.ID>) async {
        await bulkUpdateAnnotations(
            undoName: String(localized: "Prüfstatus"),
            failureMessage: String(localized: "Status konnte nicht gespeichert werden."),
            for: targetIDs
        ) { $0.reviewed = reviewed }
    }

    func bulkExclude(_ excluded: Bool, for targetIDs: Set<Transaction.ID>) async {
        await bulkUpdateAnnotations(
            undoName: String(localized: "Analyse-Ausschluss"),
            failureMessage: String(localized: "Ausschluss konnte nicht gespeichert werden."),
            for: targetIDs
        ) { $0.excludedFromAnalytics = excluded }
    }

    /// Bulk-Tags (Roadmap #17): Tag zu mehreren Transaktionen hinzufügen
    /// bzw. entfernen. Aktionen laufen über die Annotation-Repo-SoT.
    func bulkAddTag(_ tagID: UUID, for targetIDs: Set<Transaction.ID>) async {
        await bulkUpdateAnnotations(
            undoName: String(localized: "Tags"),
            failureMessage: String(localized: "Tag konnte nicht zugewiesen werden."),
            for: targetIDs
        ) { annotation in
            var ids = annotation.tagIDs ?? []
            if !ids.contains(tagID) { ids.append(tagID) }
            annotation.tagIDs = ids
        }
    }

    func bulkRemoveTag(_ tagID: UUID, for targetIDs: Set<Transaction.ID>) async {
        await bulkUpdateAnnotations(
            undoName: String(localized: "Tags"),
            failureMessage: String(localized: "Tag konnte nicht entfernt werden."),
            for: targetIDs
        ) { $0.tagIDs = ($0.tagIDs ?? []).filter { $0 != tagID } }
    }

    private struct BulkAnnotationChange: Sendable {
        let transaction: Transaction
        let previous: TransactionAnnotation?
        let updated: TransactionAnnotation
    }

    /// Gemeinsamer Pfad aller Annotation-Sammelaktionen: ein Schreibvorgang,
    /// ein Undo-Schritt.
    private func bulkUpdateAnnotations(
        undoName: String,
        failureMessage: String,
        for targetIDs: Set<Transaction.ID>,
        mutate: (inout TransactionAnnotation) -> Void
    ) async {
        let targets = transactions.filter { targetIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        do {
            let now = Date()
            var changes: [BulkAnnotationChange] = []
            for target in targets {
                let previous = try await existingAnnotation(for: target)
                var annotation = try await annotation(for: target)
                mutate(&annotation)
                annotation.updatedAt = now
                changes.append(BulkAnnotationChange(transaction: target, previous: previous, updated: annotation))
            }
            try await dependencies.transactionAnnotationRepository.upsert(changes.map(\.updated))
            for change in changes {
                if let idx = transactions.firstIndex(where: { $0.id == change.transaction.id }) {
                    transactions[idx] = effectiveTransactionResolver.applying(annotation: change.updated, to: transactions[idx])
                }
            }
            markLocallyChanged()
            pushUndo(
                name: "\(undoName) (\(changes.count))",
                revert: { [weak self] in
                    guard let self else { return }
                    for change in changes {
                        await self.restore(annotation: change.previous, transaction: change.transaction)
                    }
                },
                apply: { [weak self] in
                    guard let self else { return }
                    for change in changes {
                        await self.restore(annotation: change.updated, transaction: change.transaction)
                    }
                }
            )
        } catch {
            errorMessage = failureMessage
        }
    }
}
