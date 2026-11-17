import Foundation

/// Teil von `TransactionsModel` (nach Thema aufgeteilt, Roadmap 7.3).
extension TransactionsModel {
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

    func dismissMerchantCategoryOffer() {
        merchantCategoryOffer = nil
    }

    /// Die Lernregel für den Händler dieser Buchung, dieselbe, die auch die
    /// Prüfliste anlegt. `nil`, wenn der Händler nicht erkennbar ist.
    func merchantRule(for transaction: Transaction, categoryID: Category.ID) async throws
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
    func merchantSiblings(
        of transaction: Transaction,
        matching rule: CategoryRule,
        categoryID: Category.ID
    ) async throws -> [Transaction] {
        let compiled = CategoryRuleEngine().compile([rule])
        return try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
            .filter { $0.id != transaction.id && $0.categoryID != categoryID && compiled.firstMatch(for: $0) != nil }
    }

    /// Der Händler hat weitere Buchungen, aber weder Regeln noch Branchenwort
    /// würden eine neue Buchung von ihm so einordnen.
    func isRepeatMerchantWithoutAutomaticCategory(
        _ transaction: Transaction,
        matching rule: CategoryRule,
        categoryID: Category.ID
    ) async throws -> Bool {
        var probe = transaction
        probe.categoryID = nil
        CategoryRuleEngine().apply(try await dependencies.ruleRepository.rules(), to: &probe)
        guard probe.categoryID != categoryID else { return false }
        let compiled = CategoryRuleEngine().compile([rule])
        return try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
            .contains { $0.id != transaction.id && compiled.firstMatch(for: $0) != nil }
    }

    func prepareMerchantCategoryOffer(for transaction: Transaction) async {
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
            // Händler mit weiteren Buchungen, den noch nichts von selbst so
            // zuordnet: einmal fragen. Sonst kommt jede neue Buchung wieder
            // ohne Kategorie, obwohl die früheren längst zugeordnet sind.
            var repeatsUnlearned = false
            if siblings.isEmpty, !contradictsRule, existing == nil {
                repeatsUnlearned = try await isRepeatMerchantWithoutAutomaticCategory(
                    transaction,
                    matching: rule,
                    categoryID: categoryID
                )
            }
            guard !siblings.isEmpty || contradictsRule || repeatsUnlearned else { return }
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
                        self.actionError = String(localized: "Rückgängig konnte nicht angewendet werden.")
                    }
                },
                apply: { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.writeMerchantCategory(changed, rule: rule, deletingRuleID: nil)
                    } catch {
                        self.actionError = String(localized: "Änderung konnte nicht gespeichert werden.")
                    }
                }
            )
        } catch {
            actionError = String(localized: "Die Kategorie konnte nicht für alle Buchungen des Händlers übernommen werden.")
        }
    }

    /// Schreibt Buchungen und Händler-Regel und zieht die geladene Liste nach.
    func writeMerchantCategory(
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
            actionError = String(localized: "Die Kategorie wurde gesetzt, konnte für diesen Händler aber nicht gemerkt werden.")
        }
        await prepareMerchantCategoryOffer(for: updated)
    }

    /// Legt die Händler-Regel an und ordnet bislang unkategorisierte
    /// Buchungen des Händlers zu.
    func learnMerchant(from updated: Transaction, categoryID: Category.ID) async throws {
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
            actionError = String(localized: "Die Regel konnte nicht gespeichert werden.")
            return false
        }
    }
}
