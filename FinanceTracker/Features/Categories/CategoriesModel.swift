import Foundation

struct CategoryGroup: Identifiable, Hashable, Sendable {
    let parent: Category
    let children: [CategoryWithCount]
    let totalCount: Int

    var id: UUID { parent.id }
}

struct CategoryWithCount: Identifiable, Hashable, Sendable {
    let category: Category
    let ownCount: Int

    var id: UUID { category.id }
}

@MainActor
@Observable
final class CategoriesModel {
    let dependencies: AppDependencies

    private(set) var groups: [CategoryGroup] = []
    private(set) var rules: [CategoryRule] = []
    private(set) var categoryNamesByID: [UUID: String] = [:]
    /// Händlernamen für Regeln, die an einem erkannten Händler hängen.
    private(set) var merchantNamesByID: [UUID: String] = [:]
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isApplyingRules = false
    private(set) var applyResultMessage: String?

    var dataRevision: Int { dependencies.changeTracker.revision }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let categoriesTask = dependencies.categoryRepository.categories()
            async let rulesTask = dependencies.ruleRepository.rules()
            // WP20/§145: Usage-Counts per Pushdown statt Full-History-Txns.
            async let usageTask = dependencies.categoryRepository.usageCounts()

            let categories = try await categoriesTask.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let fetchedRules = try await rulesTask
            let countsByID = try await usageTask
            merchantNamesByID = Dictionary(
                (try await dependencies.merchantRepository.merchants()).map { ($0.id, $0.displayName) },
                uniquingKeysWith: { first, _ in first }
            )

            buildGroups(categories: categories, countsByID: countsByID)
            categoryNamesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
            rules = CategoryRuleEngine().orderedRules(fetchedRules)
        } catch {
            errorMessage = String(localized: "Die Kategorien konnten nicht geladen werden.")
        }
    }

    /// Was die Regel prüft: bei Händler-Regeln mit dem Händlernamen statt
    /// einer internen Kennung.
    func conditionText(for rule: CategoryRule) -> String {
        if case .merchantIDEquals(let merchantID) = rule.condition {
            return merchantNamesByID[merchantID].map { String(localized: "Händler ist „\($0)“") }
                ?? String(localized: "Händler (nicht mehr vorhanden)")
        }
        return rule.condition.displayText
    }

    func ruleDetailText(for rule: CategoryRule) -> String {
        let category = categoryNamesByID[rule.categoryID] ?? String(localized: "Unbekannte Kategorie")
        return rule.origin == .user
            ? String(localized: "→ \(category) · deine Regel")
            : String(localized: "→ \(category) · Standardregel")
    }

    func toggleRule(_ rule: CategoryRule) async {
        var updated = rule
        updated.enabled.toggle()
        await persist(updated)
    }

    func deleteRule(_ rule: CategoryRule) async {
        do {
            try await dependencies.ruleRepository.delete(id: rule.id)
            rules.removeAll { $0.id == rule.id }
            dependencies.changeTracker.markChanged()
        } catch {
            errorMessage = String(localized: "Die Regel konnte nicht gelöscht werden.")
        }
    }

    // MARK: - Category CRUD (Roadmap #47–50)

    func createCategory(name: String, icon: String, color: CategoryColorToken, parentID: UUID?) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            errorMessage = String(localized: "Bitte einen Namen eingeben.")
            return
        }
        let category = Category(
            name: trimmed,
            systemIconName: icon.isEmpty ? "tag" : icon,
            colorToken: color,
            parentID: parentID
        )
        do {
            try await dependencies.categoryRepository.upsert([category])
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            errorMessage = String(localized: "Kategorie konnte nicht erstellt werden.")
        }
    }

    func update(_ category: Category) async {
        do {
            try await dependencies.categoryRepository.upsert([category])
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            errorMessage = String(localized: "Kategorie konnte nicht gespeichert werden.")
        }
    }

    /// Löscht eine Kategorie. Parent-Kategorien mit Kindern werden
    /// abgelehnt (erst Kinder entfernen oder verschieben).
    func delete(_ category: Category, reassignTo newCategoryID: UUID?) async {
        if category.parentID == nil {
            let hasChildren = groups.contains { $0.parent.id == category.id && !$0.children.isEmpty }
            if hasChildren {
                errorMessage = String(localized: "Bitte erst Unterkategorien verschieben oder löschen.")
                return
            }
        }

        do {
            try await dependencies.categoryRepository.delete(id: category.id, reassignTo: newCategoryID)
            // Regeln, die auf die gelöschte Kategorie zielten, entfernen.
            for rule in rules where rule.categoryID == category.id {
                try await dependencies.ruleRepository.delete(id: rule.id)
            }
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            errorMessage = String(localized: "Kategorie konnte nicht gelöscht werden.")
        }
    }

    func transactionCount(for category: Category) -> Int {
        if category.parentID == nil {
            return groups.first { $0.parent.id == category.id }?.totalCount ?? 0
        }
        return groups.flatMap(\.children).first { $0.category.id == category.id }?.ownCount ?? 0
    }

    func applyRulesToAllTransactions() async {
        guard !isApplyingRules else { return }
        isApplyingRules = true
        defer { isApplyingRules = false }

        do {
            let categories = try await dependencies.categoryRepository.categories()
            let assignableCategoryIDs = Set(
                CategoryHierarchy().assignableCategories(in: categories).map(\.id)
            )
            let changedIDs = try await dependencies.transactionRepository.assignCategoriesToUncategorized(
                matching: rules,
                assignableCategoryIDs: assignableCategoryIDs
            )
            if !changedIDs.isEmpty {
                dependencies.changeTracker.markChanged()
            }
            applyResultMessage = changedIDs.isEmpty
                ? String(localized: "Keine Transaktionen ohne Kategorie gefunden.")
                : String(localized: "\(changedIDs.count) Transaktionen kategorisiert.")
        } catch {
            applyResultMessage = String(localized: "Regeln konnten nicht angewendet werden.")
        }
    }

    private func persist(_ rule: CategoryRule) async {
        do {
            try await dependencies.ruleRepository.upsert([rule])
            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[index] = rule
            }
        } catch {
            errorMessage = String(localized: "Die Regel konnte nicht gespeichert werden.")
        }
    }

    private func buildGroups(categories: [Category], countsByID: [UUID: Int]) {
        let parents = categories.filter { $0.parentID == nil }
        groups = parents.map { parent in
            let children = categories.filter { $0.parentID == parent.id }
            let childrenWithCounts = children.map { CategoryWithCount(category: $0, ownCount: countsByID[$0.id] ?? 0) }
            let childrenSum = children.reduce(into: 0) { partial, child in
                partial += countsByID[child.id] ?? 0
            }
            return CategoryGroup(
                parent: parent,
                children: childrenWithCounts,
                totalCount: (countsByID[parent.id] ?? 0) + childrenSum
            )
        }
    }
}
