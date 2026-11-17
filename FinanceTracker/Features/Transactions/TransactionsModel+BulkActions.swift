import Foundation

/// Teil von `TransactionsModel` (nach Thema aufgeteilt, Roadmap 7.3).
extension TransactionsModel {
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
        await deleteManualTransactions([transaction])
    }

    /// Die manuell erfassten Buchungen einer Auswahl; Bank- und Importdaten
    /// bleiben, auch wenn sie mit ausgewählt sind.
    func manuallyDeletable(in ids: Set<Transaction.ID>) -> [Transaction] {
        visibleTransactions.filter { ids.contains($0.id) && canDeleteManually($0) }
    }

    /// Rückfrage vor dem Löschen einer Auswahl: nennt, was verschwindet und
    /// was bleibt.
    static func selectionDeletionMessage(_ request: SelectionDeletion) -> String {
        let count = request.targets.count
        var message = String(localized: "\(count) manuell erfasste Buchungen werden entfernt. Angehängte Belege werden mitgelöscht.")
        if request.selectedCount > count {
            message += " " + String(localized: "Bankbuchungen in der Auswahl bleiben erhalten.")
        }
        return message
    }

    /// Stellt die Rückfrage für die manuellen Buchungen einer Auswahl.
    func requestDeletion(ofSelection ids: Set<Transaction.ID>) {
        let manual = manuallyDeletable(in: ids)
        guard let first = manual.first else { return }
        if ids.count == 1 {
            transactionPendingDeletion = first
        } else {
            selectionPendingDeletion = SelectionDeletion(targets: manual, selectedCount: ids.count)
        }
    }

    /// Löscht mehrere manuelle Buchungen in einem Schritt (bei Transfers
    /// jeweils beide Seiten). Ohne Belege ist der Schritt per ⌘Z rückholbar.
    func deleteManualTransactions(_ targets: [Transaction]) async {
        let deletable = targets.filter(canDeleteManually)
        guard !deletable.isEmpty else { return }
        do {
            var ids = Set(deletable.map(\.id))
            let counterpartIDs = Set(deletable.compactMap(Self.transferCounterpartExternalID(for:)))
            if !counterpartIDs.isEmpty {
                let manual = try await dependencies.transactionRepository
                    .transactions(matching: TransactionQuery(sources: [.manual]))
                for counterpart in manual where counterpart.externalID.map(counterpartIDs.contains) == true {
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
                name: ids.count == 1 ? String(localized: "Löschen") : String(localized: "Löschen (\(ids.count))"),
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
                        self.actionError = String(localized: "Rückgängig konnte nicht angewendet werden.")
                    }
                },
                apply: { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.dependencies.transactionRepository.deleteTransactions(ids: ids)
                        self.transactions.removeAll { ids.contains($0.id) }
                        self.markLocallyChanged()
                    } catch {
                        self.actionError = String(localized: "Die Buchung konnte nicht gelöscht werden.")
                    }
                }
            )
        } catch {
            actionError = String(localized: "Die Buchung konnte nicht gelöscht werden.")
        }
    }

    func bulkChangeCategory(_ categoryID: UUID?, for targetIDs: Set<Transaction.ID>) async {
        let targets = transactions.filter { targetIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        do {
            // Rohzeilen ändern, nicht die annotation-aufgelösten
            // Listenobjekte (siehe `persistAndResync`).
            let storedByID = try await storedTransactions(for: Set(targets.map(\.id)))
            let previous = targets.compactMap { storedByID[$0.id] }
            let now = Date()
            let updates = previous.map { stored -> Transaction in
                var updated = stored
                updated.categoryID = categoryID
                updated.updatedAt = now
                return updated
            }
            guard !updates.isEmpty else { return }
            try await dependencies.transactionRepository.upsert(updates)
            let updatedIDs = Set(updates.map(\.id))
            for index in transactions.indices where updatedIDs.contains(transactions[index].id) {
                transactions[index].categoryID = categoryID
                transactions[index].updatedAt = now
            }
            markLocallyChanged()
            // Auch Sammel-Aktionen sind ein Undo-Schritt, sonst
            // nähme ⌘Z stillschweigend eine ältere, fremde Änderung zurück.
            pushUndo(
                name: String(localized: "Kategorie (\(updates.count))"),
                revert: { [weak self] in
                    guard let self else { return }
                    for stored in previous {
                        await self.persistAndResync(
                            stored: stored,
                            failureMessage: String(localized: "Rückgängig konnte nicht angewendet werden.")
                        )
                    }
                },
                apply: { [weak self] in
                    guard let self else { return }
                    for update in updates { await self.persistAndResync(stored: update) }
                }
            )
        } catch {
            actionError = String(localized: "Bulk-Kategorie konnte nicht gespeichert werden.")
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
    func bulkUpdateAnnotations(
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
            actionError = failureMessage
        }
    }
}
