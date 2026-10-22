import Foundation
import os

/// MacUX-Automatisierung („so wenig Arbeit wie möglich für den User"):
/// Der eingebaute System-Katalog: Standardkategorien + Händler-Merkregeln
/// (REWE → Lebensmittel, Netflix → Abos, …): gehört zu JEDER Installation,
/// nicht nur zu Preview-Daten. Früher wurde der Katalog nur zusammen mit
/// künstlichen Daten erzeugt und beim lokalen Datenreset wieder gelöscht:
/// Echte Installationen starteten dadurch ohne jede Automatik.
///
/// Eigenschaften:
/// - Idempotent: Kategorien und System-Regeln haben stabile IDs
///   (Category.defaultCatalog()/stableSystemRuleID) → Upsert ohne Duplikate.
/// - Versioniert: Einmal pro Katalog-Version läuft ein Rückfill, der noch
///   offene (kategorielose) Buchungen per Regel matcht. Nur positive
///   Treffer, niemals ein „Sonstiges"-Fallback.
/// - User gewinnt: User-Regeln schlagen System-Regeln (RuleEngine sortiert
///   origin-first), bestehende Kategorien werden nie überschrieben, und
///   deaktivierte System-Regeln bleiben deaktiviert.
@MainActor
struct SystemCatalogSeeder {
    private static let logger = Logger(
        subsystem: "de.klabautter.FinanceTracker",
        category: "SystemCatalogSeeder"
    )

    static let defaultsKey = "systemCatalog.appliedVersion"

    /// Bei neuen Katalog-Einträgen hochzählen: löst Re-Seed + Rückfill aus.
    /// v5 (01.09.2026): Sichere Enable-Banking-Händler ergänzt und starke
    /// Eigenübertrags-Signale als Transfer normalisiert. „Sparrate" ist nur
    /// mit erkennbarem Eigenkonto automatisch; Zinserträge sind signumsicher.
    /// Kein generischer „Sonstiges"-Fallback; uneindeutige Händler bleiben prüfbar.
    /// v6 (13.10.2026): Kategorie „Geldanlage", Lieferdienst-Regeln und
    /// Branchenwörter im Händlernamen (`MerchantKeywordCategorizer`).
    /// v7 (13.10.2026): Wortliste um Ketten, Marken und fremdsprachige
    /// Branchenwörter erweitert; liest auch den ungekürzten Händlertext.
    /// v8 (20.10.2026): PayPal-Buchungen bekommen den Händler aus dem
    /// Verwendungszweck („Ihr Einkauf bei …") und werden danach eingeordnet.
    /// v9 (21.10.2026): Händlernamen ohne Rechtsform und mit bis zu vier
    /// Wörtern: früher auf drei gekürzte Namen („urban homes for") werden
    /// verlängert.
    /// v10 (21.10.2026): Fixkosten übernehmen die verlängerten Händlernamen.
    /// v11 (21.10.2026): Internationale Ketten (UK, US, FR, ES, IT, NL) in
    /// der Händlerliste: offene Buchungen werden damit erneut zugeordnet.
    static let catalogVersion = 11

    let dependencies: AppDependencies
    private let defaults: UserDefaults

    init(dependencies: AppDependencies, defaults: UserDefaults = .standard) {
        self.dependencies = dependencies
        self.defaults = defaults
    }

    func seedIfNeeded() async {
        do {
            let appliedVersion = defaults.integer(forKey: Self.defaultsKey)
            let storedRules = try await dependencies.ruleRepository.rules()
            let catalogTemplate = CategoryRule.defaultCatalog()
            let storedRuleIDs = Set(storedRules.map(\.id))
            let missingStableRules = catalogTemplate.contains { !storedRuleIDs.contains($0.id) }
            let unsafeLegacyRules = storedRules.filter(Self.isUnsafeLegacyDescriptionRule)
            // „ruleCount == 0" fängt frische Installationen UND den Fall
            // „Demo-Daten entfernen" (Reset löscht auch Regeln) ab.
            guard appliedVersion < Self.catalogVersion
                    || storedRules.isEmpty
                    || missingStableRules
                    || unsafeLegacyRules.contains(where: \.enabled) else { return }

            try await dependencies.categoryRepository.upsert(Category.defaultCatalog())

            let existingByID = Dictionary(
                uniqueKeysWithValues: storedRules.map { ($0.id, $0) }
            )
            var catalog = catalogTemplate
            for index in catalog.indices {
                if let existing = existingByID[catalog[index].id] {
                    catalog[index].enabled = existing.enabled
                } else {
                    // Migration von Katalogen vor stabilen IDs: Wurde eine
                    // semantisch gleiche alte Regel deaktiviert, bleibt diese
                    // Entscheidung auch für die neue stabile Regel erhalten.
                    let equivalents = storedRules.filter {
                        Self.hasSameSystemMeaning($0, catalog[index])
                    }
                    if equivalents.contains(where: { !$0.enabled }) {
                        catalog[index].enabled = false
                    }
                }
            }
            try await dependencies.ruleRepository.upsert(catalog)
            let catalogIDs = Set(catalog.map(\.id))
            let redundantLegacyRules = storedRules.filter { stored in
                guard stored.origin == .system, !catalogIDs.contains(stored.id) else { return false }
                return catalog.contains { Self.hasSameSystemMeaning(stored, $0) }
            }
            let legacyRulesToDisable = unsafeLegacyRules + redundantLegacyRules
            if !legacyRulesToDisable.isEmpty {
                let disabledLegacyRules = Dictionary(
                    uniqueKeysWithValues: legacyRulesToDisable.map { ($0.id, $0) }
                ).values.map { rule in
                    var disabled = rule
                    disabled.enabled = false
                    return disabled
                }
                try await dependencies.ruleRepository.upsert(disabledLegacyRules)
            }

            let categories = try await dependencies.categoryRepository.categories()
            let intermediaryCount = try await backfillPaymentIntermediaryMerchants(with: catalog, categories: categories)
            let renamedMerchants = try await backfillTruncatedMerchantNames()
            let assignedCount = try await backfillUncategorized(with: catalog, categories: categories)
            let transferCount = try await backfillStrongTransferSignals()
            let kindCount = try await backfillUnknownKinds()

            defaults.set(Self.catalogVersion, forKey: Self.defaultsKey)
            dependencies.changeTracker.markChanged()
            Self.logger.notice("System-Katalog v\(Self.catalogVersion) angewendet, Rückfill-Kategorien: \(assignedCount, privacy: .public), Rückfill-Transfers: \(transferCount, privacy: .public), Rückfill-Typen: \(kindCount, privacy: .public), PayPal-Händler: \(intermediaryCount, privacy: .public), Händlernamen: \(renamedMerchants, privacy: .public)")
        } catch {
            Self.logger.error("System-Katalog-Seeding fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Kategorie und Typ müssen dieselbe effektive Semantik liefern. Deshalb
    /// werden nur bereits durch eine aktive Regel als „Umbuchungen" erkannte
    /// Buchungen mit einem starken Textsignal zu Transfers. Eine User-Regel,
    /// die eine andere Kategorie gewählt hat, bleibt unangetastet.
    private func backfillStrongTransferSignals() async throws -> Int {
        let all = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let annotations = try await dependencies.transactionAnnotationRepository.annotations(
            transactionIDs: Set(all.map(\.id))
        )
        let manualKindIDs = Set(annotations.compactMap { annotation in
            annotation.manualKindOverride == nil ? nil : annotation.transactionID
        })

        let updates = all.compactMap { transaction -> Transaction? in
            guard transaction.categoryID == Category.transfers.id,
                  !manualKindIDs.contains(transaction.id),
                  TransactionKindInference.hasStrongTransferSignal(
                    rawDescription: transaction.rawDescription,
                    merchantName: transaction.rawMerchantName ?? transaction.effectiveMerchantName
                  ),
                  transaction.kind != .transfer else { return nil }
            var updated = transaction
            updated.kind = .transfer
            updated.updatedAt = Date()
            return updated
        }
        guard !updates.isEmpty else { return 0 }
        try await dependencies.transactionRepository.upsert(updates)
        return updates.count
    }

    /// Rückfill: nur Buchungen OHNE Kategorie, nur positive Regel-Treffer.
    /// User-Regeln schlagen System-Regeln (RuleEngine sortiert origin-first).
    private func backfillUncategorized(
        with catalog: [CategoryRule],
        categories: [Category]
    ) async throws -> Int {
        let userRules = try await dependencies.ruleRepository.rules().filter { $0.origin == .user }
        let allRules = userRules + catalog
        let assignableCategoryIDs = Set(CategoryHierarchy().assignableCategories(in: categories).map(\.id))
        return try await dependencies.transactionRepository.assignCategoriesToUncategorized(
            matching: allRules,
            assignableCategoryIDs: assignableCategoryIDs
        ).count
    }

    /// PayPal-Rückfill (v8): Händler hinter der Zahlung übernehmen; nur
    /// Buchungen ohne Kategorie werden danach per Regel eingeordnet.
    private func backfillPaymentIntermediaryMerchants(
        with catalog: [CategoryRule],
        categories: [Category]
    ) async throws -> Int {
        let all = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let userRules = try await dependencies.ruleRepository.rules().filter { $0.origin == .user }
        let assignableCategoryIDs = Set(CategoryHierarchy().assignableCategories(in: categories).map(\.id))
        let rules = CategoryRuleEngine().compile(userRules + catalog, assignableCategoryIDs: assignableCategoryIDs)
        var knownMerchants = try await dependencies.merchantRepository.merchants()
        var merchantUpserts: [Merchant.ID: Merchant] = [:]
        var updates: [Transaction] = []

        for transaction in all {
            guard let name = PaymentIntermediaryResolver.underlyingMerchant(
                rawMerchantName: transaction.rawMerchantName,
                rawDescription: transaction.rawDescription
            ) else { continue }
            let resolution = MerchantNormalizer().resolve(rawDescriptor: name, knownMerchants: knownMerchants)
            guard resolution.displayName != transaction.merchantDisplayName
                    || resolution.merchantID != transaction.merchantID else { continue }
            if let merchant = resolution.merchantToUpsert {
                merchantUpserts[merchant.id] = merchant
                if let index = knownMerchants.firstIndex(where: { $0.id == merchant.id }) {
                    knownMerchants[index] = merchant
                } else {
                    knownMerchants.append(merchant)
                }
            }
            var updated = transaction
            updated.merchantDisplayName = resolution.displayName
            updated.merchantID = resolution.merchantID
            rules.apply(to: &updated)
            updated.updatedAt = Date()
            updates.append(updated)
        }
        guard !updates.isEmpty else { return 0 }
        if !merchantUpserts.isEmpty {
            try await dependencies.merchantRepository.upsert(Array(merchantUpserts.values))
        }
        try await dependencies.transactionRepository.upsert(updates)
        return updates.count
    }

    /// Händlernamen-Rückfill (v9): Nur automatisch gekürzte Namen (genau
    /// drei Wörter, Anfang des neuen Namens) werden verlängert: vom Nutzer
    /// gewählte Namen bleiben.
    private func backfillTruncatedMerchantNames() async throws -> Int {
        let normalizer = MerchantNormalizer()
        var renamed: [Merchant.ID: String] = [:]
        var merchantUpdates: [Merchant] = []
        for merchant in try await dependencies.merchantRepository.merchants() {
            let words = merchant.displayName.split(separator: " ")
            guard words.count == 3 else { continue }
            let candidates = merchant.aliases.compactMap { normalizer.canonicalDisplayName(from: $0) }
            guard let longer = candidates.first(where: { $0.hasPrefix(merchant.displayName + " ") }) else { continue }
            var updated = merchant
            updated.displayName = longer
            merchantUpdates.append(updated)
            renamed[merchant.id] = longer
        }
        try await renameCommitmentsAfterMerchants()
        guard !renamed.isEmpty else { return 0 }
        try await dependencies.merchantRepository.upsert(merchantUpdates)
        let transactions = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let updates = transactions.compactMap { transaction -> Transaction? in
            guard let merchantID = transaction.merchantID, let name = renamed[merchantID],
                  transaction.merchantDisplayName != name else { return nil }
            var updated = transaction
            updated.merchantDisplayName = name
            return updated
        }
        if !updates.isEmpty {
            try await dependencies.transactionRepository.upsert(updates)
        }
        return renamed.count
    }

    /// Bestätigte Fixkosten tragen eine Kopie des Händlernamens. Wurde der
    /// Händler verlängert („urban homes for" → „… students"), zieht die
    /// Fixkost nach: sofern der Nutzer sie nicht umbenannt hat.
    private func renameCommitmentsAfterMerchants() async throws {
        let merchantsByID = Dictionary(
            (try await dependencies.merchantRepository.merchants()).map { ($0.id.uuidString, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let updates = try await dependencies.recurringCommitmentRepository.commitments().compactMap { commitment -> RecurringCommitment? in
            guard let key = commitment.matchingMerchantKey, let merchant = merchantsByID[key],
                  merchant.displayName.hasPrefix(commitment.name + " ") else { return nil }
            var updated = commitment
            updated.name = merchant.displayName
            updated.updatedAt = Date()
            return updated
        }
        if !updates.isEmpty {
            try await dependencies.recurringCommitmentRepository.upsert(updates)
        }
    }

    /// Typ-Rückfill (v3): Buchungen mit `kind == .unknown` erhalten den
    /// deterministischen Betragssignal-Typ, identisch zur Import-Inferenz.
    /// Nur echte Unbekannte werden angefasst (kein Überschreiben).
    private func backfillUnknownKinds() async throws -> Int {
        let all = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let unknowns = all.filter { $0.kind == .unknown }
        guard !unknowns.isEmpty else { return 0 }

        let inferred = unknowns.map { transaction -> Transaction in
            var updated = transaction
            updated.kind = TransactionKindInference.inferredKind(
                for: updated.amount,
                current: updated.kind
            )
            return updated
        }
        try await dependencies.transactionRepository.upsert(inferred)
        return inferred.count
    }

    private static func isUnsafeLegacyDescriptionRule(_ rule: CategoryRule) -> Bool {
        guard rule.origin == .system else { return false }
        switch rule.condition {
        case .merchantContains(let value):
            let key = CategoryRuleEngine.normalizedKey(value)
            return key == "MIETE" || key == "GEHALT" || key == "LOHN"
        case .descriptionContains(let value):
            // „Sparrate" kann auch ein Kauf (etwa ETF-Sparplan) sein.
            return CategoryRuleEngine.normalizedKey(value) == "SPARRATE"
        case .merchantEquals(let value):
            // Die alte Regel ignorierte das Betragssignum.
            return CategoryRuleEngine.normalizedKey(value) == "ZINSGUTSCHRIFT"
        default:
            return false
        }
    }

    private static func hasSameSystemMeaning(_ lhs: CategoryRule, _ rhs: CategoryRule) -> Bool {
        guard lhs.origin == .system, rhs.origin == .system,
              lhs.categoryID == rhs.categoryID else { return false }
        return conditionKey(lhs.condition) == conditionKey(rhs.condition)
    }

    private static func conditionKey(_ condition: RuleCondition) -> String {
        switch condition {
        case .merchantEquals(let value):
            "merchantEquals|\(CategoryRuleEngine.normalizedKey(value))"
        case .merchantContains(let value):
            "merchantContains|\(CategoryRuleEngine.normalizedKey(value))"
        case .descriptionContains(let value):
            "descriptionContains|\(CategoryRuleEngine.normalizedKey(value))"
        case .descriptionContainsDebit(let value):
            "descriptionContainsDebit|\(CategoryRuleEngine.normalizedKey(value))"
        case .descriptionContainsCredit(let value):
            "descriptionContainsCredit|\(CategoryRuleEngine.normalizedKey(value))"
        case .merchantIDEquals(let id):
            "merchantIDEquals|\(id.uuidString)"
        }
    }
}
