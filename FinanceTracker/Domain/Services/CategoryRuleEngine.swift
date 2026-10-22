import Foundation

enum RuleCondition: Hashable, Codable, Sendable {
    case merchantEquals(String)
    case merchantContains(String)
    case descriptionContains(String)
    case descriptionContainsDebit(String)
    case descriptionContainsCredit(String)
    case merchantIDEquals(UUID)

    var displayText: String {
        switch self {
        case .merchantEquals(let value): String(localized: "Händler ist „\(value)“")
        case .merchantContains(let value): String(localized: "Händler enthält „\(value)“")
        case .descriptionContains(let value): String(localized: "Beschreibung enthält „\(value)“")
        case .descriptionContainsDebit(let value): String(localized: "Ausgabe-Beschreibung enthält „\(value)“")
        case .descriptionContainsCredit(let value): String(localized: "Einnahme-Beschreibung enthält „\(value)“")
        case .merchantIDEquals: String(localized: "Händler (identifiziert)")
        }
    }
}

enum CategoryRuleOrigin: String, Codable, Sendable {
    case system
    case user
}

struct CategoryRule: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var priority: Int
    var condition: RuleCondition
    var categoryID: Category.ID
    var enabled: Bool
    var origin: CategoryRuleOrigin

    init(
        id: UUID = UUID(),
        priority: Int,
        condition: RuleCondition,
        categoryID: Category.ID,
        enabled: Bool = true,
        origin: CategoryRuleOrigin = .user
    ) {
        self.id = id
        self.priority = priority
        self.condition = condition
        self.categoryID = categoryID
        self.enabled = enabled
        self.origin = origin
    }
}

struct CategoryRuleEngine: Sendable {
    struct CompiledRules: Sendable {
        fileprivate struct Entry: Sendable {
            let rule: CategoryRule
            let condition: CompiledCondition
        }

        fileprivate enum CompiledCondition: Sendable {
            case merchantEquals(String)
            case merchantContains([String])
            case descriptionContains([String])
            case descriptionContainsDebit([String])
            case descriptionContainsCredit([String])
            case merchantIDEquals(UUID)
        }

        fileprivate let entries: [Entry]
        /// `nil` = keine Einschränkung (alle Kategorien zuweisbar).
        fileprivate let assignableCategoryIDs: Set<Category.ID>?

        func firstMatch(for transaction: Transaction) -> CategoryRule? {
            allMatches(for: transaction).first
        }

        /// Alle passenden Regeln (statt nur der ersten), für
        /// Verlauf-Vorschläge (`CategorySuggestionService` stimmt über alle
        /// Treffer ab, statt nur den ersten zu werten).
        func allMatches(for transaction: Transaction) -> [CategoryRule] {
            let merchantKey = CategoryRuleEngine.normalizedKey(transaction.effectiveMerchantName)
            let descriptionKey = CategoryRuleEngine.normalizedKey(transaction.rawDescription ?? "")
            let merchantTokens = merchantKey.split(separator: " ")
            let descriptionTokens = descriptionKey.split(separator: " ")

            var matches: [CategoryRule] = []
            for entry in entries {
                let hit: Bool
                switch entry.condition {
                case .merchantIDEquals(let merchantID):
                    hit = transaction.merchantID == merchantID
                case .merchantEquals(let value):
                    hit = merchantKey == value
                case .merchantContains(let tokens):
                    hit = CategoryRuleEngine.containsTokenSequence(merchantTokens, tokens)
                case .descriptionContains(let tokens):
                    hit = CategoryRuleEngine.containsTokenSequence(descriptionTokens, tokens)
                case .descriptionContainsDebit(let tokens):
                    hit = transaction.amount.isNegative
                        && CategoryRuleEngine.containsTokenSequence(descriptionTokens, tokens)
                case .descriptionContainsCredit(let tokens):
                    hit = transaction.amount.isPositive
                        && CategoryRuleEngine.containsTokenSequence(descriptionTokens, tokens)
                }
                if hit { matches.append(entry.rule) }
            }
            return matches
        }

        @discardableResult
        func apply(to transaction: inout Transaction, beforeKeywords preferredCategoryID: Category.ID? = nil) -> Bool {
            guard transaction.categoryID == nil else { return false }
            if let match = firstMatch(for: transaction) {
                transaction.categoryID = match.categoryID
                return true
            }
            // Sicherer als ein Branchenwort: z. B. eine an der Gegenseite
            // erkannte Umbuchung aufs eigene Konto.
            if let preferredCategoryID, assignableCategoryIDs?.contains(preferredCategoryID) ?? true {
                transaction.categoryID = preferredCategoryID
                return true
            }
            // Keine Regel passt: Branchenwort im Händlernamen als letzte Stufe.
            if let keywordCategoryID = MerchantKeywordCategorizer.categoryID(for: transaction),
               assignableCategoryIDs?.contains(keywordCategoryID) ?? true {
                transaction.categoryID = keywordCategoryID
                return true
            }
            return false
        }
    }

    static func normalizedKey(_ input: String) -> String {
        input.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func containsTokenSequence(_ normalizedInput: String, _ normalizedNeedle: String) -> Bool {
        let inputTokens = normalizedInput.split(separator: " ")
        let needleTokens = normalizedNeedle.split(separator: " ").map(String.init)
        return containsTokenSequence(inputTokens, needleTokens)
    }

    private static func containsTokenSequence(
        _ inputTokens: [Substring],
        _ needleTokens: [String]
    ) -> Bool {
        guard !needleTokens.isEmpty, needleTokens.count <= inputTokens.count else { return false }

        for start in 0...(inputTokens.count - needleTokens.count) {
            let candidate = inputTokens[start..<(start + needleTokens.count)]
            if candidate.elementsEqual(needleTokens, by: { $0 == $1 }) {
                return true
            }
        }
        return false
    }

    func sortedRules(_ rules: [CategoryRule]) -> [CategoryRule] {
        orderedRules(rules.filter(\.enabled))
    }

    /// Dieselbe Vorrangfolge für Ausführung und vollständige Regelanzeige.
    func orderedRules(_ rules: [CategoryRule]) -> [CategoryRule] {
        rules.sorted {
            if $0.origin != $1.origin { return $0.origin == .user }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Sortiert, validiert und normalisiert einen Regelkatalog genau einmal.
    /// Große Imports und Bestandsläufe verwenden danach nur noch vorbereitete
    /// Strings bzw. Tokenfolgen pro Transaktion.
    func compile(
        _ rules: [CategoryRule],
        assignableCategoryIDs: Set<Category.ID>? = nil
    ) -> CompiledRules {
        let entries = sortedRules(rules).compactMap { rule -> CompiledRules.Entry? in
            if let assignableCategoryIDs,
               !assignableCategoryIDs.contains(rule.categoryID) {
                return nil
            }

            let condition: CompiledRules.CompiledCondition
            switch rule.condition {
            case .merchantIDEquals(let merchantID):
                condition = .merchantIDEquals(merchantID)
            case .merchantEquals(let value):
                condition = .merchantEquals(Self.normalizedKey(value))
            case .merchantContains(let value):
                condition = .merchantContains(Self.normalizedKey(value).split(separator: " ").map(String.init))
            case .descriptionContains(let value):
                condition = .descriptionContains(Self.normalizedKey(value).split(separator: " ").map(String.init))
            case .descriptionContainsDebit(let value):
                condition = .descriptionContainsDebit(Self.normalizedKey(value).split(separator: " ").map(String.init))
            case .descriptionContainsCredit(let value):
                condition = .descriptionContainsCredit(Self.normalizedKey(value).split(separator: " ").map(String.init))
            }
            return CompiledRules.Entry(rule: rule, condition: condition)
        }
        return CompiledRules(entries: entries, assignableCategoryIDs: assignableCategoryIDs)
    }

    func firstMatch(
        in rules: [CategoryRule],
        for transaction: Transaction,
        assignableCategoryIDs: Set<Category.ID>? = nil
    ) -> CategoryRule? {
        compile(rules, assignableCategoryIDs: assignableCategoryIDs)
            .firstMatch(for: transaction)
    }

    @discardableResult
    func apply(
        _ rules: [CategoryRule],
        assignableCategoryIDs: Set<Category.ID>? = nil,
        to transaction: inout Transaction
    ) -> Bool {
        compile(rules, assignableCategoryIDs: assignableCategoryIDs)
            .apply(to: &transaction)
    }
}

extension CategoryRule {
    static func makeFromCorrection(
        transaction: Transaction,
        categoryID: Category.ID,
        existingRules: [CategoryRule]
    ) -> CategoryRule? {
        let condition: RuleCondition
        if let merchantID = transaction.merchantID {
            condition = .merchantIDEquals(merchantID)
        } else {
            let rawMerchant = transaction.effectiveMerchantName.trimmingCharacters(in: .whitespacesAndNewlines)
            let merchantName = Self.strippedVariableTokens(from: rawMerchant)
            guard !merchantName.isEmpty, merchantName != "Unbekannt" else { return nil }
            condition = .merchantContains(merchantName)
        }

        if var existing = existingRules.first(where: {
            $0.origin == .user && $0.condition.hasSameLearningKey(as: condition)
        }) {
            existing.condition = condition
            existing.categoryID = categoryID
            existing.enabled = true
            return existing
        }

        return CategoryRule(
            // Eine neue explizite Korrektur muss vor älteren, breiteren
            // User-Regeln greifen. Bei identischem Lernschlüssel wird oben
            // weiterhin dieselbe Regel aktualisiert.
            priority: (existingRules.filter { $0.origin == .user }.map(\.priority).min() ?? 1) - 1,
            condition: condition,
            categoryID: categoryID,
            origin: .user
        )
    }

    static func strippedVariableTokens(from input: String) -> String {
        let tokens = input
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let meaningful = tokens.filter { token in
            !token.allSatisfy { $0.isNumber } && token.rangeOfCharacter(from: .decimalDigits) == nil
        }
        return (meaningful.isEmpty ? tokens : meaningful).joined(separator: " ")
    }

    static func defaultCatalog() -> [CategoryRule] {
        let catalog = Category.defaultCatalog()
        let assignableIDs = Set(CategoryHierarchy().assignableCategories(in: catalog).map(\.id))

        var rules: [CategoryRule] = []
        func add(_ priority: Int, _ condition: RuleCondition, _ categoryName: String) {
            guard let categoryID = catalog.first(where: { $0.name == categoryName })?.id,
                  assignableIDs.contains(categoryID) else { return }
            rules.append(CategoryRule(
                id: stableSystemRuleID(condition: condition, categoryName: categoryName),
                priority: priority,
                condition: condition,
                categoryID: categoryID,
                origin: .system
            ))
        }

        add(100, .merchantContains("REWE"), "Lebensmittel")
        add(101, .merchantContains("BILLA"), "Lebensmittel")
        add(102, .merchantContains("SPAR"), "Lebensmittel")
        add(103, .merchantContains("LIDL"), "Lebensmittel")
        add(104, .merchantContains("HOFER"), "Lebensmittel")
        add(170, .merchantContains("EDEKA"), "Lebensmittel")
        add(171, .merchantContains("NETTO"), "Lebensmittel")
        add(172, .merchantContains("KAUFLAND"), "Lebensmittel")
        add(173, .merchantContains("PENNY"), "Lebensmittel")
        add(174, .merchantContains("ALDI"), "Lebensmittel")
        add(175, .merchantContains("TEGUT"), "Lebensmittel")
        add(110, .merchantEquals("McDonald's"), "Restaurants")
        add(114, .merchantContains("MCDONALDS"), "Restaurants")
        add(115, .merchantContains("MCDONALD'S"), "Restaurants")
        add(111, .merchantContains("PIZZERIA"), "Restaurants")
        add(112, .merchantContains("KEBAP"), "Restaurants")
        add(113, .merchantContains("CAFÉ CENTRAL"), "Restaurants")
        add(180, .merchantContains("LIEFERANDO"), "Restaurants")
        add(181, .merchantContains("WOLT"), "Restaurants")
        add(228, .merchantContains("FOODORA"), "Restaurants")
        // Vor der allgemeinen UBER-Regel (Taxi, 122): niedrigere Zahl gewinnt.
        add(119, .merchantContains("UBER EATS"), "Restaurants")
        add(230, .merchantContains("MJAM"), "Restaurants")
        add(182, .merchantContains("BURGER KING"), "Restaurants")
        add(183, .merchantContains("STARBUCKS"), "Restaurants")
        add(184, .merchantContains("SUBWAY"), "Restaurants")
        add(185, .merchantEquals("RESTAURANT"), "Restaurants")
        add(186, .merchantContains("VAPIANO"), "Restaurants")
        add(120, .merchantContains("SHELL"), "Tanken")
        add(162, .merchantContains("ARAL"), "Tanken")
        add(163, .merchantContains("ESSO"), "Tanken")
        add(121, .merchantContains("WIENER LINIEN"), "ÖPNV")
        add(190, .merchantContains("DEUTSCHE BAHN"), "Reisen")
        add(191, .merchantContains("DB VERTRIEB"), "Reisen")
        add(192, .merchantContains("FLIXBUS"), "Reisen")
        add(122, .merchantContains("UBER"), "Taxi")
        add(123, .merchantContains("BOLT"), "Taxi")
        add(130, .merchantContains("SPOTIFY"), "Abos")
        add(131, .merchantContains("NETFLIX"), "Abos")
        add(132, .merchantContains("APPLE"), "Abos")
        add(133, .merchantContains("ICLOUD"), "Abos")
        add(134, .merchantContains("ADOBE"), "Abos")
        add(135, .merchantContains("MAGENTA TELEKOM"), "Abos")
        add(200, .merchantContains("STEAM"), "Abos")
        add(201, .merchantContains("DISNEY"), "Abos")
        add(140, .merchantContains("AMAZON"), "Shopping")
        add(141, .merchantContains("AMZN"), "Shopping")
        add(142, .merchantContains("ZALANDO"), "Shopping")
        add(143, .merchantContains("MEDIAMARKT"), "Shopping")
        add(144, .merchantContains("MEDIA MARKT"), "Shopping")
        add(210, .merchantContains("IKEA"), "Shopping")
        add(211, .merchantContains("ACTION"), "Shopping")
        add(150, .merchantEquals("dm"), "Gesundheit")
        add(152, .merchantContains("DM DROGERIE"), "Gesundheit")
        add(151, .merchantContains("APOTHEKE"), "Gesundheit")
        add(212, .merchantContains("ROSSMANN"), "Gesundheit")
        add(214, .merchantContains("FITINN"), "Gesundheit")
        add(215, .merchantContains("WIEN ENERGIE"), "Energie & Nebenkosten")
        add(216, .merchantEquals("HOTEL"), "Reisen")
        add(217, .merchantContains("ÖBB"), "Reisen")
        add(218, .merchantContains("OEBB"), "Reisen")
        add(219, .merchantContains("OMV"), "Tanken")
        add(220, .merchantContains("BANKOMAT"), "Bargeld")
        add(164, .merchantContains("BARGELD"), "Bargeld")
        add(160, .descriptionContainsCredit("GEHALT"), "Einkünfte")
        add(213, .descriptionContainsCredit("LOHN"), "Einkünfte")
        add(225, .descriptionContainsCredit("HABENZINSEN"), "Einkünfte")
        add(226, .descriptionContainsCredit("ZINSGUTSCHRIFT"), "Einkünfte")
        add(161, .descriptionContainsDebit("MIETE"), "Miete")
        add(221, .merchantEquals("EIGENES TAGESGELD"), "Umbuchungen")
        add(227, .merchantEquals("EIGENES GIROKONTO"), "Umbuchungen")
        add(222, .descriptionContains("UMBUCHUNG"), "Umbuchungen")
        add(223, .descriptionContains("EIGENÜBERTRAG"), "Umbuchungen")
        add(224, .descriptionContains("EIGENUEBERTRAG"), "Umbuchungen")

        return rules
    }

    /// Stabile System-Regel-IDs (FNV-1a über Bedingung+Kategorie): Upserts
    /// sind idempotent, und der Katalog darf erweitert/umsortiert werden,
    /// ohne dass IDs wandern. KEIN Hashable-Hash: der ist pro Prozess
    /// gesalzen und würde Laufzeit-übergreifend brechen.
    private static func stableSystemRuleID(condition: RuleCondition, categoryName: String) -> UUID {
        let conditionKey: String
        switch condition {
        case .merchantEquals(let value): conditionKey = "me|\(value)"
        case .merchantContains(let value): conditionKey = "mc|\(value)"
        case .descriptionContains(let value): conditionKey = "dc|\(value)"
        case .descriptionContainsDebit(let value): conditionKey = "dd|\(value)"
        case .descriptionContainsCredit(let value): conditionKey = "cr|\(value)"
        case .merchantIDEquals(let id): conditionKey = "mi|\(id.uuidString)"
        }
        let seed = "financetracker.sysrule|\(conditionKey)|\(categoryName)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return UUID(uuidString: String(format: "000000CC-0000-0000-0000-%012llX", hash & 0xFFFF_FFFF_FFFF))!
    }
}

private extension RuleCondition {
    func hasSameLearningKey(as other: RuleCondition) -> Bool {
        switch (self, other) {
        case (.merchantIDEquals(let lhs), .merchantIDEquals(let rhs)):
            return lhs == rhs
        case (.merchantContains(let lhs), .merchantContains(let rhs)):
            return CategoryRuleEngine.normalizedKey(lhs) == CategoryRuleEngine.normalizedKey(rhs)
        default:
            return false
        }
    }
}
