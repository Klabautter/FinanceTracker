import Foundation

/// Ein Review-Fall entspricht genau einer Transaktion. Der Domain-Builder
/// liefert bewusst einen Eintrag pro Grund; für den Workspace werden diese
/// Gründe zusammengeführt, damit dieselbe Buchung nicht mehrfach erscheint.
struct ReviewQueueEntry: Identifiable, Hashable, Sendable {
    enum PrimaryAction: Sendable, Equatable {
        case categorize
        case confirmTransfer
        case complete
    }

    let transaction: Transaction
    let reasons: [ReviewItem.Reason]
    let linkedTransactionID: UUID?

    var id: Transaction.ID { transaction.id }

    var primaryAction: PrimaryAction {
        if reasons.contains(.possibleTransfer), linkedTransactionID != nil {
            return .confirmTransfer
        }
        if reasons.contains(.uncategorized) {
            return .categorize
        }
        return .complete
    }

    func item(for reason: ReviewItem.Reason? = nil) -> ReviewItem {
        ReviewItem(
            transaction: transaction,
            reason: reason ?? reasons.first ?? .uncategorized,
            linkedTransactionID: linkedTransactionID
        )
    }
}

struct ReviewCategoryGroup: Identifiable, Hashable, Sendable {
    let parent: Category
    let categories: [Category]

    var id: Category.ID { parent.id }
}

@MainActor
@Observable
final class ReviewQueueModel {
    enum CategoryAssignmentScope: Sendable {
        case transactionOnly
        case merchant
    }

    private let dependencies: AppDependencies
    private let effectiveTransactionResolver = EffectiveTransactionResolver()
    private let suggestionService = CategorySuggestionService()

    private(set) var items: [ReviewItem] = []
    private(set) var categories: [Category] = []
    private(set) var accountsByID: [UUID: Account] = [:]
    /// Verlauf-Vorschläge pro offener Transaktions-ID (Händler-Modus aus
    /// kategorisierten Buchungen, gleiche Lernregel-Semantik wie der
    /// Merkregel-Pfad: was der Vorschlag verspricht, hält die Regel).
    private(set) var suggestions: [Transaction.ID: CategorySuggestion] = [:]
    /// Läuft gerade die Vorschlagssuche über das Sprachmodell des Geräts?
    private(set) var isAdvising = false
    /// Antworten des Modells je Händler (auch „kein Vorschlag"), damit jeder
    /// Name nur einmal gefragt wird; die Liste lädt nach jeder Zuordnung neu.
    private var adviceByMerchantKey: [String: MerchantCategoryAdvice?] = [:]

    /// Vorschlag des Sprachmodells für eine noch nicht vorhandene Kategorie.
    struct NewCategoryProposal: Equatable, Sendable {
        let name: String
        let parentID: Category.ID?
    }

    /// Offene Ausgaben, für die das Modell eine neue Kategorie vorschlägt.
    /// Gleiche Vorschläge verschiedener Händler tragen denselben Namen, damit
    /// aus „Versicherung“ und „Versicherungen“ nicht zwei Kategorien werden.
    private(set) var newCategoryProposals: [Transaction.ID: NewCategoryProposal] = [:]
    private var adviceTask: Task<Void, Never>?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// MacUX-Audit: Transaktionen, für die eine Kategorie-Merkregel erstellt
    /// wurde (Bestätigung im Row-Button; Wiederholungstäter verschwinden
    /// damit dauerhaft aus der Queue).
    private(set) var createdRuleTransactionIDs: Set<UUID> = []
    private(set) var processingTransactionIDs: Set<Transaction.ID> = []

    /// Neue Kategorie direkt beim Zuordnen anlegen (optional vorbelegt, z. B.
    /// mit einem Vorschlag des Sprachmodells).
    struct CategoryCreationRequest: Identifiable {
        let id = UUID()
        let entry: ReviewQueueEntry
        let scope: CategoryAssignmentScope
        var suggestedName: String?
        var suggestedParentID: Category.ID?
    }

    var categoryCreationRequest: CategoryCreationRequest?

    var dependenciesForCategoryEditor: AppDependencies { dependencies }

    func requestCategoryCreation(for entry: ReviewQueueEntry, suggestedName: String? = nil, suggestedParentID: Category.ID? = nil) {
        categoryCreationRequest = CategoryCreationRequest(
            entry: entry,
            scope: canRememberMerchant(for: entry) ? .merchant : .transactionOnly,
            suggestedName: suggestedName,
            suggestedParentID: suggestedParentID
        )
    }

    func categoryCreated(_ category: Category, for request: CategoryCreationRequest) async {
        if let fetched = try? await dependencies.categoryRepository.categories() {
            categories = fetched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        await assignCategory(request.entry.item(for: .uncategorized), categoryID: category.id, scope: request.scope)
        // Andere Händler mit demselben Vorschlag bekommen jetzt die angelegte
        // Kategorie vorgeschlagen.
        applyCachedAdvice()
    }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let candidatesTask = dependencies.transactionRepository.reviewCandidateTransactions()
            async let categoriesTask = dependencies.categoryRepository.categories()
            async let accountsTask = dependencies.accountRepository.accounts()
            async let historyTask = dependencies.transactionRepository.recentTransactions(limit: 2000)

            // WP14 (§101-104): Die Queue arbeitet auf der LEICHTE Projection
            // (kein Full-Domain-Hydration) und ist GLOBAL, ältere offene
            // Reviews sind erreichbar; der Dashboard-Count nutzt dieselbe
            // Semantik.
            let candidates = try await resolveAnnotations(for: try await candidatesTask)
            let fetchedCategories = try await categoriesTask
            let fetchedAccounts = try await accountsTask

            items = ReviewQueueBuilder().buildItems(
                transactions: candidates,
                baseCurrency: dependencies.baseCurrency
            )
            categories = fetchedCategories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            accountsByID = Dictionary(uniqueKeysWithValues: fetchedAccounts.map { ($0.id, $0) })

            // Verlauf-Vorschläge sind Kür (best-effort): Schlägt der
            // Verlauf-Load fehl, bleibt die Queue ohne Vorschläge nutzbar.
            let history: [Transaction]
            do {
                history = try await historyTask
            } catch {
                history = []
            }
            let openUncategorized = items
                .filter { $0.reason == .uncategorized }
                .map(\.transaction)
            suggestions = suggestionService.suggestions(
                uncategorized: openUncategorized,
                history: history,
                categories: fetchedCategories
            )
            startAdvising()
        } catch {
            errorMessage = String(localized: "Die Prüfliste konnte nicht geladen werden.")
        }
    }

    // MARK: - Vorschläge aus dem Händlernamen (Sprachmodell des Geräts)

    /// Höchstens so viele Händler pro Durchlauf fragen.
    private static let adviceBatchLimit = 200

    private func adviceKey(for transaction: Transaction) -> String {
        CategoryRuleEngine.normalizedKey(transaction.effectiveMerchantName)
    }

    /// Offene Ausgaben ohne Kategorie und ohne Verlauf-Vorschlag.
    private var adviceTargets: [Transaction] {
        items
            .filter { $0.reason == .uncategorized }
            .map(\.transaction)
            .filter { $0.amount.isNegative && suggestions[$0.id]?.origin != .history }
    }

    private func applyCachedAdvice() {
        let assignable = assignableCategories
        let assignableIDs = Set(assignable.map(\.id))
        var canonicalNames: [String: String] = [:]
        newCategoryProposals = [:]
        for transaction in adviceTargets {
            guard let cached = adviceByMerchantKey[adviceKey(for: transaction)], let advice = cached else { continue }
            switch advice {
            case .existing(let categoryID):
                guard assignableIDs.contains(categoryID) else { continue }
                suggestions[transaction.id] = CategorySuggestion(categoryID: categoryID, supportCount: 0, origin: .deviceModel)
            case .newCategory(let name, let parentID):
                // Inzwischen angelegt (z. B. für einen anderen Händler)? Dann
                // ist es ein ganz normaler Vorschlag.
                if let existing = NewCategoryProposalPolicy.existingMatch(for: name, in: assignable) {
                    suggestions[transaction.id] = CategorySuggestion(categoryID: existing.id, supportCount: 0, origin: .deviceModel)
                    continue
                }
                let key = NewCategoryProposalPolicy.key(name)
                let canonical = canonicalNames[key] ?? name
                canonicalNames[key] = canonical
                newCategoryProposals[transaction.id] = NewCategoryProposal(name: canonical, parentID: parentID)
            }
        }
    }

    func newCategoryProposal(for entry: ReviewQueueEntry) -> NewCategoryProposal? {
        guard suggestions[entry.id] == nil else { return nil }
        return newCategoryProposals[entry.id]
    }

    /// Fragt das Modell nacheinander für jeden noch unbekannten Händler und
    /// blendet Vorschläge ein, sobald sie da sind. Ohne Modell passiert nichts.
    private func startAdvising() {
        adviceTask?.cancel()
        guard let advisor = dependencies.categoryAdvisor, advisor.isAvailable else {
            isAdvising = false
            return
        }
        applyCachedAdvice()

        var seen = Set<String>()
        let pending = adviceTargets
            .map { (key: adviceKey(for: $0), name: $0.effectiveMerchantName) }
            .filter { !$0.key.isEmpty && adviceByMerchantKey[$0.key] == nil && seen.insert($0.key).inserted }
            .prefix(Self.adviceBatchLimit)
        guard !pending.isEmpty else {
            isAdvising = false
            return
        }

        // Umbuchungen, Einkünfte und Geldanlage sind keine Alltagsausgaben.
        let excluded: Set<Category.ID> = [Category.transfers.id, Category.income.id, Category.investments.id]
        let candidates = assignableCategories.filter { !excluded.contains($0.id) }
        // Neue Kategorien nur unter Gruppen, die schon Unterkategorien haben,
        // eine einzelne Kategorie wie „Gesundheit“ würde sonst zur Gruppe und
        // wäre selbst nicht mehr zuweisbar.
        let parents = categoryGroups.map(\.parent).filter { parent in
            !excluded.contains(parent.id) && categories.contains { $0.parentID == parent.id }
        }
        isAdvising = true
        adviceTask = Task { [weak self] in
            for entry in pending {
                let advice = await advisor.adviseCategory(
                    merchantName: entry.name,
                    isIncome: false,
                    candidates: candidates,
                    parents: parents
                )
                guard !Task.isCancelled, let self else { return }
                self.adviceByMerchantKey[entry.key] = .some(advice)
                self.applyCachedAdvice()
            }
            self?.isAdvising = false
        }
    }

    var parentCategories: [Category] {
        categories.filter { $0.parentID == nil }
    }

    /// WP12: Nur Leaves sind zuweisbar (Parents = aggregation-only).
    var assignableCategories: [Category] {
        CategoryHierarchy().assignableCategories(in: categories)
    }

    /// Für die Darstellung nach Parent gruppiert, ohne Parents zuweisbar zu
    /// machen. Root-Leaves bleiben als eigenständige Optionen erreichbar.
    var categoryGroups: [ReviewCategoryGroup] {
        let assignableIDs = Set(assignableCategories.map(\.id))
        return categories
            .filter { $0.parentID == nil }
            .compactMap { parent in
                let children = categories
                    .filter { $0.parentID == parent.id && assignableIDs.contains($0.id) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                guard !children.isEmpty else { return nil }
                return ReviewCategoryGroup(parent: parent, categories: children)
            }
            .sorted { $0.parent.name.localizedCaseInsensitiveCompare($1.parent.name) == .orderedAscending }
    }

    var standaloneCategories: [Category] {
        let parentIDs = Set(categoryGroups.map(\.parent.id))
        return assignableCategories.filter { category in
            category.parentID == nil || !parentIDs.contains(category.parentID ?? category.id)
        }
    }

    var entries: [ReviewQueueEntry] {
        let grouped = Dictionary(grouping: items, by: { $0.transaction.id })
        return grouped.values.compactMap { transactionItems in
            guard let first = transactionItems.first else { return nil }
            let reasons = ReviewItem.Reason.allCases.filter { reason in
                transactionItems.contains { $0.reason == reason }
            }
            return ReviewQueueEntry(
                transaction: first.transaction,
                reasons: reasons,
                linkedTransactionID: transactionItems.compactMap(\.linkedTransactionID).first
            )
        }
        .sorted { lhs, rhs in
            if lhs.primaryAction.sortPriority != rhs.primaryAction.sortPriority {
                return lhs.primaryAction.sortPriority < rhs.primaryAction.sortPriority
            }
            if lhs.primaryAction == .categorize {
                let lhsKey = merchantGroupingKey(for: lhs.transaction)
                let rhsKey = merchantGroupingKey(for: rhs.transaction)
                if lhsKey != rhsKey { return lhsKey < rhsKey }
            }
            return lhs.transaction.displayDate > rhs.transaction.displayDate
        }
    }

    func entries(for action: ReviewQueueEntry.PrimaryAction) -> [ReviewQueueEntry] {
        entries.filter { $0.primaryAction == action }
    }

    /// Zählt ausschließlich offene, unkategorisierte Fälle, die von exakt
    /// derselben Merkregel erfasst würden. Damit verspricht die UI keine
    /// heuristische Ähnlichkeit, die der persistierte Regelpfad nicht hält.
    func similarUncategorizedCount(for entry: ReviewQueueEntry) -> Int {
        guard let rule = CategoryRule.makeFromCorrection(
            transaction: entry.transaction,
            categoryID: UUID(),
            existingRules: []
        ) else { return 0 }

        let engine = CategoryRuleEngine()
        return entries.reduce(into: 0) { count, candidate in
            guard candidate.reasons.contains(.uncategorized) else { return }
            if engine.firstMatch(in: [rule], for: candidate.transaction) != nil {
                count += 1
            }
        }
    }

    func isProcessing(_ entry: ReviewQueueEntry) -> Bool {
        processingTransactionIDs.contains(entry.id)
    }

    func canRememberMerchant(for entry: ReviewQueueEntry) -> Bool {
        CategoryRule.makeFromCorrection(
            transaction: entry.transaction,
            categoryID: UUID(),
            existingRules: []
        ) != nil
    }

    func accountName(for transaction: Transaction) -> String {
        accountsByID[transaction.accountID]?.name ?? String(localized: "Unbekanntes Konto")
    }

    func categoryName(for transaction: Transaction) -> String? {
        guard let categoryID = transaction.categoryID else { return nil }
        return categories.first { $0.id == categoryID }?.name
    }

    /// Kategorisieren-Einträge mit Verlauf-Vorschlag (für Bulk-Übernahme).
    var suggestedCategorizeEntries: [ReviewQueueEntry] {
        entries(for: .categorize).filter { suggestions[$0.id] != nil }
    }

    /// Sammel-Übernahme nur für Vorschläge aus dem eigenen Verlauf. Was das
    /// Sprachmodell aus dem Namen liest, kann danebenliegen und würde als
    /// Händler-Regel dauerhaft wirken, das bestätigt der Nutzer einzeln.
    var bulkAcceptableEntries: [ReviewQueueEntry] {
        suggestedCategorizeEntries.filter { suggestions[$0.id]?.origin == .history }
    }

    func suggestionCategory(for entry: ReviewQueueEntry) -> (Category, Int)? {
        guard let suggestion = suggestions[entry.id],
              let category = categories.first(where: { $0.id == suggestion.categoryID }) else {
            return nil
        }
        return (category, suggestion.supportCount)
    }

    /// 1-Klick: Vorschlag übernehmen, mit Händler-Regel (Scope `.merchant`),
    /// sodass alle ähnlichen mitgeprüft werden und der Händler nie wieder
    /// auftaucht. Ohne Merkregel-Möglichkeit gilt die Auswahl nur für diese
    /// Transaktion.
    func acceptSuggestion(_ entry: ReviewQueueEntry) async {
        guard let suggestion = suggestions[entry.id] else { return }
        await assignCategory(
            entry.item(for: .uncategorized),
            categoryID: suggestion.categoryID,
            scope: canRememberMerchant(for: entry) ? .merchant : .transactionOnly
        )
    }

    /// Bulk: alle Verlauf-Vorschläge übernehmen. Jeder Händler wird genau einmal
    /// angefasst, nach der Händler-Zuweisung verlieren Geschwister ihren
    /// `.uncategorized`-Grund und werden übersprungen.
    func acceptAllSuggestions() async {
        for entry in bulkAcceptableEntries {
            let stillOpen = items.contains {
                $0.transaction.id == entry.id && $0.reason == .uncategorized
            }
            guard stillOpen else { continue }
            await acceptSuggestion(entry)
        }
    }

    func assignCategory(
        _ item: ReviewItem,
        categoryID: UUID,
        scope: CategoryAssignmentScope = .transactionOnly
    ) async {
        let operationIDs: Set<Transaction.ID>
        if scope == .merchant {
            operationIDs = matchingUncategorizedTransactionIDs(for: item.transaction)
        } else {
            operationIDs = [item.transaction.id]
        }
        guard processingTransactionIDs.isDisjoint(with: operationIDs) else { return }
        processingTransactionIDs.formUnion(operationIDs)
        defer { processingTransactionIDs.subtract(operationIDs) }
        guard CategoryHierarchy().isAssignable(categoryID, in: categories) else {
            errorMessage = String(localized: "Diese Kategorie kann Transaktionen nicht direkt zugewiesen werden.")
            return
        }
        do {
            // WP14: Das Item stammt aus der LEICHTEN Projection: vor einer
            // Mutation die vollständige Transaktion laden, damit keine
            // Felder der Persistenz verloren gehen.
            guard var updated = try await dependencies.transactionRepository.transaction(id: item.transaction.id) else {
                errorMessage = String(localized: "Die Transaktion konnte nicht geladen werden.")
                return
            }
            updated.categoryID = categoryID
            updated.updatedAt = Date()

            try await dependencies.transactionRepository.upsert([updated])
            var affectedIDs: Set<Transaction.ID> = [updated.id]

            if scope == .merchant {
                let existingRules = try await dependencies.ruleRepository.rules()
                guard let rule = CategoryRule.makeFromCorrection(
                    transaction: updated,
                    categoryID: categoryID,
                    existingRules: existingRules
                ) else {
                    errorMessage = String(localized: "Für diesen Händler kann keine sichere Merkregel erstellt werden.")
                    return
                }
                if existingRules.first(where: { $0.id == rule.id }) != rule {
                    try await dependencies.ruleRepository.upsert([rule])
                }
                affectedIDs.formUnion(
                    try await dependencies.transactionRepository.assignCategoriesToUncategorized(
                        matching: [rule],
                        assignableCategoryIDs: [categoryID]
                    )
                )
                createdRuleTransactionIDs.insert(updated.id)
            }

            items = items.compactMap { existingItem in
                guard affectedIDs.contains(existingItem.transaction.id) else { return existingItem }
                guard existingItem.reason != .uncategorized else { return nil }
                var transaction = existingItem.transaction
                transaction.categoryID = categoryID
                return ReviewItem(
                    transaction: transaction,
                    reason: existingItem.reason,
                    linkedTransactionID: existingItem.linkedTransactionID
                )
            }
            errorMessage = nil
            dependencies.changeTracker.markChanged()
        } catch {
            errorMessage = String(localized: "Die Kategorie konnte nicht gespeichert werden.")
        }
    }

    func markReviewed(_ item: ReviewItem) async {
        guard processingTransactionIDs.insert(item.transaction.id).inserted else { return }
        defer { processingTransactionIDs.remove(item.transaction.id) }
        do {
            var annotation = try await annotation(for: item.transaction)
            annotation.reviewed = true
            annotation.updatedAt = Date()
            try await dependencies.transactionAnnotationRepository.upsert([annotation])
            items.removeAll { $0.transaction.id == item.transaction.id }
            errorMessage = nil
            dependencies.changeTracker.markChanged()
        } catch {
            errorMessage = String(localized: "Der Prüfstatus konnte nicht gespeichert werden.")
        }
    }

    /// MacUX-Audit („sollte das nicht automatisch funktionieren?"): Merkregel
    /// aus der Queue heraus, nach dem Zuweisen kann der Händler gemerkt
    /// werden, damit künftige Importe automatisch kategorisieren und das
    /// Item nie wieder auftaucht. Gleiche Semantik wie
    /// TransactionsModel.createRule (CategoryRule.makeFromCorrection,
    /// kein Doppel-Eintrag).
    func createRule(for item: ReviewItem) async {
        guard processingTransactionIDs.insert(item.transaction.id).inserted else { return }
        defer { processingTransactionIDs.remove(item.transaction.id) }
        guard let categoryID = item.transaction.categoryID else { return }
        guard CategoryHierarchy().isAssignable(categoryID, in: categories) else { return }
        do {
            let existingRules = try await dependencies.ruleRepository.rules()
            guard let rule = CategoryRule.makeFromCorrection(
                transaction: item.transaction,
                categoryID: categoryID,
                existingRules: existingRules
            ) else { return }
            if existingRules.first(where: { $0.id == rule.id }) != rule {
                try await dependencies.ruleRepository.upsert([rule])
            }
            _ = try await dependencies.transactionRepository.assignCategoriesToUncategorized(
                matching: [rule],
                assignableCategoryIDs: [categoryID]
            )
            createdRuleTransactionIDs.insert(item.transaction.id)
            errorMessage = nil
            dependencies.changeTracker.markChanged()
        } catch {
            errorMessage = String(localized: "Die Regel konnte nicht gespeichert werden.")
        }
    }

    func markAsTransfer(_ item: ReviewItem, linkedTransactionID: UUID?) async {
        let operationIDs = Set([item.transaction.id, linkedTransactionID].compactMap { $0 })
        guard processingTransactionIDs.isDisjoint(with: operationIDs) else { return }
        processingTransactionIDs.formUnion(operationIDs)
        defer { processingTransactionIDs.subtract(operationIDs) }
        do {
            let transfersCategory = try await dependencies.categoryRepository.categories()
                .first { $0.id == Category.transfers.id }

            // WP14: Vollständige Transaktionen laden (leichte Projection
            // nie zurückschreiben).
            guard var main = try await dependencies.transactionRepository.transaction(id: item.transaction.id) else {
                errorMessage = String(localized: "Die Transaktion konnte nicht geladen werden.")
                return
            }
            var updates: [Transaction] = []
            var annotations: [TransactionAnnotation] = []
            var mainAnnotation = try await annotation(for: main)
            mainAnnotation.manualKindOverride = .transfer
            mainAnnotation.reviewed = true
            mainAnnotation.updatedAt = Date()
            annotations.append(mainAnnotation)
            if let linkedTransactionID,
               let linked = try await dependencies.transactionRepository.transaction(id: linkedTransactionID) {
                var linkedUpdated = linked
                var linkedAnnotation = try await annotation(for: linkedUpdated)
                linkedAnnotation.manualKindOverride = .transfer
                linkedAnnotation.reviewed = true
                linkedAnnotation.updatedAt = Date()
                annotations.append(linkedAnnotation)
                if let cat = transfersCategory { linkedUpdated.categoryID = cat.id }
                linkedUpdated.updatedAt = Date()
                updates.append(linkedUpdated)
            }
            if let cat = transfersCategory { main.categoryID = cat.id }
            main.updatedAt = Date()
            updates.append(main)

            try await dependencies.transactionRepository.upsert(updates)
            try await dependencies.transactionAnnotationRepository.upsert(annotations)
            let affectedIDs = Set(updates.map(\.id))
            items.removeAll { affectedIDs.contains($0.transaction.id) }
            errorMessage = nil
            dependencies.changeTracker.markChanged()
        } catch {
            errorMessage = String(localized: "Der Transfer konnte nicht gespeichert werden. Die Transaktionen bleiben unverändert.")
        }
    }

    private func resolveAnnotations(for transactions: [Transaction]) async throws -> [Transaction] {
        let annotations = try await dependencies.transactionAnnotationRepository.annotations(
            transactionIDs: Set(transactions.map(\.id))
        )
        return effectiveTransactionResolver.applying(annotations: annotations, to: transactions)
    }

    private func annotation(for transaction: Transaction) async throws -> TransactionAnnotation {
        if let existing = try await dependencies.transactionAnnotationRepository.annotation(transactionID: transaction.id) {
            return existing
        }
        return TransactionAnnotation.legacyFallback(for: transaction)
    }

    private func merchantGroupingKey(for transaction: Transaction) -> String {
        if let merchantID = transaction.merchantID {
            return "0|\(merchantID.uuidString)"
        }
        return "1|\(CategoryRuleEngine.normalizedKey(transaction.effectiveMerchantName))"
    }

    private func matchingUncategorizedTransactionIDs(for transaction: Transaction) -> Set<Transaction.ID> {
        guard let rule = CategoryRule.makeFromCorrection(
            transaction: transaction,
            categoryID: UUID(),
            existingRules: []
        ) else { return [transaction.id] }

        let engine = CategoryRuleEngine()
        return Set(entries.compactMap { candidate in
            guard candidate.reasons.contains(.uncategorized),
                  engine.firstMatch(in: [rule], for: candidate.transaction) != nil else {
                return nil
            }
            return candidate.id
        })
    }
}

private extension ReviewQueueEntry.PrimaryAction {
    var sortPriority: Int {
        switch self {
        case .categorize: 0
        case .confirmTransfer: 1
        case .complete: 2
        }
    }
}
