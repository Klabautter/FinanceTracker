import Foundation

/// Entfernt Belege zu Buchungen, die gelöscht werden: zuerst die Datei, dann
/// die Metadaten (wie beim Einzel-Löschen, §218). Wirft beim ersten Fehler;
/// der Aufrufer löscht die Buchungen dann nicht, damit nichts verwaist.
enum AttachmentCleanup {
    /// Liefert die Anzahl entfernter Belege.
    @discardableResult
    static func removeAttachments(
        of transactionIDs: Set<UUID>,
        dependencies: AppDependencies,
        baseDirectory: URL? = nil
    ) async throws -> Int {
        guard !transactionIDs.isEmpty else { return 0 }
        let attachments = try await dependencies.transactionAttachmentRepository.allAttachments()
            .filter { transactionIDs.contains($0.transactionID) }
        guard !attachments.isEmpty else { return 0 }
        let service = AttachmentService(
            attachmentsBaseDirectory: try baseDirectory ?? AttachmentService.defaultBaseDirectory()
        )
        for attachment in attachments {
            let relativePath = attachment.localRelativePath
            try await Task.detached(priority: .userInitiated) {
                try service.delete(relativePath: relativePath)
            }.value
            try await dependencies.transactionAttachmentRepository.delete(id: attachment.id)
        }
        return attachments.count
    }
}
