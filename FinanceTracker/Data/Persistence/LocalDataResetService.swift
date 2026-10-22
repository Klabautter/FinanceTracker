import Foundation

/// WP2 (§13-16): Vollständiger Reset lokaler Finanzdaten.
///
/// Dieser Service behandelt alle lokalen Finance-Daten konsistent:
/// Attachment-Dateien + Metadaten, Tag-Join-Rows, Suchindex, Annotationen,
/// Collection-Overrides, Collections, Splits, Gruppenanteile, Occurrences, Commitments,
/// Budget-History, Budgets, Import-Batches,
/// Connections, Transaktionen, Konten, Kategorien, Merchants, Rules, Tags.
///
/// Referenzielle Integrität (§15): Join-/Child-Rows vor Parent-Entities.
/// Dateisystem und Metadaten der Attachments laufen nicht auseinander:
/// Dateien werden zuerst gelöscht, schlägt eine Datei-Operation fehl, bricht
/// der Reset ab, bevor Metadaten entfernt werden.
///
/// Keychain (§16): Dieser Reset löscht KEINE Verbindungs-Credentials. Ein
/// „Alle App-Daten und Verbindungen löschen"-Flow mit Keychain-Wipe wäre
/// eine separate, explizite Nutzeraktion.
struct LocalDataResetService: Sendable {
    enum Scope: Sendable {
        /// Alle lokalen Finanzdaten inkl. abgeleiteter Indizes und
        /// Attachment-Dateien, ohne Keychain-Credentials (§16).
        case allLocalFinanceData
    }

    let dependencies: AppDependencies

    func wipe(scope: Scope = .allLocalFinanceData) async throws {
        // Attachment-Dateien VOR dem Metadata-Wipe entfernen (§15).
        let attachments = try await dependencies.transactionAttachmentRepository.allAttachments()
        if !attachments.isEmpty {
            let baseDirectory = try AttachmentService.defaultBaseDirectory()
            let service = AttachmentService(attachmentsBaseDirectory: baseDirectory)
            for attachment in attachments {
                try service.delete(relativePath: attachment.localRelativePath)
            }
        }
        try await dependencies.transactionAttachmentRepository.deleteAll()

        // Join-/Child-Rows vor Parent-Entities (§15).
        try await dependencies.tagRepository.deleteAll()
        try await dependencies.transactionAnnotationRepository.deleteAll()
        try await dependencies.transactionCollectionOverrideRepository.deleteAll()
        try await dependencies.transactionCollectionRepository.deleteAll()
        try await dependencies.transactionSplitRepository.deleteAll()
        try await dependencies.sharedExpenseShareRepository.deleteAll()
        try await dependencies.recurringCommitmentRepository.deleteAll()
        try await dependencies.budgetRepository.deleteAll()
        try await dependencies.importBatchRepository.deleteAll()
        try await dependencies.connectionRepository.deleteAll()

        // Transaktionen (inkl. abgeleiteter Suchindex), dann Parents.
        try await dependencies.transactionRepository.deleteAll()
        try await dependencies.accountRepository.deleteAll()
        try await dependencies.categoryRepository.deleteAll()
        try await dependencies.merchantRepository.deleteAll()
        try await deleteAllRules()

        dependencies.changeTracker.markChanged()
    }

    private func deleteAllRules() async throws {
        for rule in try await dependencies.ruleRepository.rules() {
            try await dependencies.ruleRepository.delete(id: rule.id)
        }
    }

    /// WP-UX: Entfernt die Demo-Datensätze (Source = demo) aus bestehenden
    /// Installationen, nach dem Deaktivieren des Auto-Seeds. Kategorien,
    /// Merchants und Rules bleiben (Standard-Katalog, von echten Daten
    /// referenziert); nur Demo-Transaktionen und -Konten werden entfernt.
    /// Läuft über dieselbe Pipeline wie der Voll-Reset (Atomar je Scope).
    func removeDemoData() async throws {
        try await dependencies.transactionRepository.deleteAllDemoTransactions()
        try await dependencies.accountRepository.deleteAllDemoAccounts()
        dependencies.changeTracker.markChanged()
    }
}
