import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import QuickLook
#endif

/// Belege/Attachments (Roadmap #143–148): Datei-Import (PDF/Bilder) per
/// Auswahl oder Ziehen aus dem Finder, Liste, Öffnen, Löschen. Dateien im
/// Dateisystem, Metadaten in SwiftData (AGENTS.md Regel 33).
/// WP16 (§114-118): iOS öffnet Belege über QuickLook-Preview.
struct TransactionAttachmentSection: View {
    let transaction: Transaction

    @State private var model: TransactionAttachmentModel
    @State private var showsImporter = false
    /// WP16: Für die QuickLook-Preview ausgewählte Datei (iOS).
    @State private var previewURL: URL?
    /// Beleg, dessen Löschen bestätigt werden muss (Datei ist danach weg).
    @State private var attachmentPendingDeletion: TransactionAttachment?

    init(transaction: Transaction, dependencies: any HasTransactionAttachmentRepository, baseDirectory: URL? = nil) {
        self.transaction = transaction
        _model = State(initialValue: TransactionAttachmentModel(
            transactionID: transaction.id,
            dependencies: dependencies,
            baseDirectory: baseDirectory
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            SectionHeader(
                title: String(localized: "Belege"),
                actionTitle: model.attachments.isEmpty ? nil : String(localized: "Hinzufügen"),
                action: model.attachments.isEmpty ? nil : { showsImporter = true }
            )

            switch ScreenState(load: model.loadState, hasContent: !model.attachments.isEmpty) {
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AppPalette.critical)
                Button("Erneut laden") { Task { await model.load() } }
                    .buttonStyle(.borderless)
            case .empty:
                Button {
                    showsImporter = true
                } label: {
                    Label("Beleg hinzufügen (PDF, Bild)…", systemImage: "paperclip")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("attachment-add-empty")
                Text("Oder eine Datei aus dem Finder hierher ziehen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .content:
                ForEach(model.attachments) { attachment in
                    row(attachment)
                }
            }

            if let removed = model.lastRemoved {
                HStack(spacing: AppSpacing.s) {
                    Text("„\(removed.attachment.fileName)“ entfernt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Rückgängig") { Task { await model.undoDelete() } }
                        .controlSize(.small)
                        .accessibilityIdentifier("attachment-undo-delete")
                }
            }

            if let actionError = model.actionError {
                Label(actionError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppPalette.critical)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .task { await model.load() }
        #if os(iOS)
        // WP16 (§115): QuickLook-Preview für PDF/Bilder.
        .quickLookPreview($previewURL)
        #endif
        // Beleg (PDF, Foto) aus dem Finder auf die Buchung ziehen.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: TransactionAttachmentModel.isSupportedFile) else { return false }
            Task { await model.importFile(url) }
            return true
        }
        .confirmationDialog(
            "Beleg löschen?",
            isPresented: Binding(
                get: { attachmentPendingDeletion != nil },
                set: { if !$0 { attachmentPendingDeletion = nil } }
            ),
            presenting: attachmentPendingDeletion
        ) { attachment in
            Button("Löschen", role: .destructive) {
                Task { await model.delete(attachment) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { attachment in
            Text("„\(attachment.fileName)“ wird von diesem Mac entfernt. Direkt danach lässt sich das noch rückgängig machen.")
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.pdf, .png, .jpeg, UTType(filenameExtension: "heic") ?? .image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await model.importFile(url) }
            case .failure(let error):
                model.reportImportFailure(error)
            }
        }
    }

    private func row(_ attachment: TransactionAttachment) -> some View {
        HStack {
            Label(attachment.fileName, systemImage: TransactionAttachmentModel.icon(for: attachment.mimeType))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                open(attachment)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Beleg \(attachment.fileName) öffnen")
            .help("Beleg öffnen")

            Button(role: .destructive) {
                attachmentPendingDeletion = attachment
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Beleg \(attachment.fileName) löschen")
            .help("Beleg löschen")
        }
    }

    private func open(_ attachment: TransactionAttachment) {
        guard let url = model.existingFileURL(for: attachment) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        // WP16 (§115/§117): Interne lokale Datei: QuickLook benötigt keine
        // Security-Scoped-Permission.
        previewURL = url
        #endif
    }
}

/// Laden, Ablegen und Löschen der Belege einer Buchung (AGENTS.md Regeln 1,
/// 24 und 37). Datei-I/O läuft abseits des MainActors.
@MainActor
@Observable
final class TransactionAttachmentModel {
    /// Nur, was dieses Model nutzt (Roadmap 7.4, `DependencyCapabilities`).
    typealias Dependencies = any HasTransactionAttachmentRepository

    private(set) var attachments: [TransactionAttachment] = []
    private(set) var loadState: LoadState = .idle
    private(set) var actionError: String?
    /// Der zuletzt entfernte Beleg samt Inhalt: bis zur nächsten Aktion
    /// lässt sich das Entfernen zurücknehmen (Roadmap 2.5).
    struct RemovedAttachment {
        let attachment: TransactionAttachment
        let data: Data
    }
    private(set) var lastRemoved: RemovedAttachment?
    private let transactionID: Transaction.ID
    private let dependencies: Dependencies
    private let baseDirectory: URL?

    init(transactionID: Transaction.ID, dependencies: Dependencies, baseDirectory: URL? = nil) {
        self.transactionID = transactionID
        self.dependencies = dependencies
        self.baseDirectory = baseDirectory
    }

    nonisolated static let supportedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "heic"]

    nonisolated static func isSupportedFile(_ url: URL) -> Bool {
        url.isFileURL && supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func icon(for mimeType: String) -> String {
        switch mimeType {
        case "application/pdf": "doc.richtext"
        case let m where m.hasPrefix("image/"): "photo"
        default: "paperclip"
        }
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "heic": "image/heic"
        default: "application/octet-stream"
        }
    }

    /// Ohne Belegordner gibt es keinen stillen Ersatzort (Regel 17): Ein
    /// temporärer Ordner würde Belege beim nächsten Aufräumen verlieren.
    private func service() throws -> AttachmentService {
        AttachmentService(attachmentsBaseDirectory: try baseDirectory ?? AttachmentService.defaultBaseDirectory())
    }

    func load() async {
        loadState = .loading
        do {
            attachments = try await dependencies.transactionAttachmentRepository.attachments(transactionID: transactionID)
            loadState = .loaded
        } catch {
            if Task.isCancelled { return }
            loadState = .failed(String(localized: "Belege konnten nicht geladen werden."))
        }
    }

    func reportImportFailure(_ error: Error) {
        actionError = String(localized: "Datei konnte nicht gelesen werden: \(error.localizedDescription)")
    }

    func importFile(_ sourceURL: URL) async {
        let mimeType = Self.mimeType(for: sourceURL)
        let transactionID = transactionID
        do {
            let service = try service()
            let secured = sourceURL.startAccessingSecurityScopedResource()
            defer { if secured { sourceURL.stopAccessingSecurityScopedResource() } }

            // WP31 (§214/§215): Copy statt RAM-Load, IO off-main.
            let stored = try await Task.detached(priority: .userInitiated) {
                try service.store(
                    sourceURL: sourceURL,
                    fileName: sourceURL.lastPathComponent,
                    mimeType: mimeType,
                    transactionID: transactionID
                )
            }.value

            try await dependencies.transactionAttachmentRepository.add(TransactionAttachment(
                id: stored.attachmentID,
                transactionID: transactionID,
                fileName: sourceURL.lastPathComponent,
                mimeType: mimeType,
                localRelativePath: stored.relativePath
            ))
            actionError = nil
            await load()
        } catch let error as AttachmentService.AttachmentServiceError {
            switch error {
            case .fileTooLarge(let maxBytes):
                actionError = String(localized: "Die Datei ist zu groß. Maximal \(maxBytes / 1024 / 1024) MB.")
            case .unsupportedMimeType(let mime):
                actionError = String(localized: "Dateityp nicht unterstützt (\(mime)). Erlaubt: PDF, PNG, JPEG, HEIC.")
            case .sourceFileUnreadable(let name):
                actionError = String(localized: "Datei konnte nicht gelesen werden: \(name).")
            case .applicationSupportUnavailable:
                actionError = String(localized: "Speicherort nicht verfügbar.")
            }
        } catch {
            actionError = String(localized: "Beleg konnte nicht gespeichert werden.")
        }
    }

    /// WP31 (§218): Datei zuerst löschen; schlägt das fehl, werden die
    /// Metadaten BEHALTEN und der Fehler gemeldet (kein stiller Verlust).
    func delete(_ attachment: TransactionAttachment) async {
        do {
            let service = try service()
            let relativePath = attachment.localRelativePath
            // Inhalt vor dem Löschen merken, damit sich der Schritt
            // zurücknehmen lässt. Fehlt die Datei schon, gibt es nichts
            // zurückzuholen; der Eintrag wird trotzdem entfernt.
            let data = try await Task.detached(priority: .userInitiated) { () -> Data? in
                let data = try? service.data(forRelativePath: relativePath)
                try service.delete(relativePath: relativePath)
                return data
            }.value
            try await dependencies.transactionAttachmentRepository.delete(id: attachment.id)
            lastRemoved = data.map { RemovedAttachment(attachment: attachment, data: $0) }
            actionError = nil
            await load()
        } catch {
            actionError = String(localized: "Beleg-Datei konnte nicht entfernt werden. Eintrag bleibt erhalten.")
        }
    }

    /// Legt den zuletzt entfernten Beleg wieder ab (Datei und Eintrag).
    func undoDelete() async {
        guard let removed = lastRemoved else { return }
        do {
            let service = try service()
            let attachment = removed.attachment
            let data = removed.data
            let stored = try await Task.detached(priority: .userInitiated) {
                try service.store(
                    data: data,
                    fileName: attachment.fileName,
                    mimeType: attachment.mimeType,
                    transactionID: attachment.transactionID
                )
            }.value
            do {
                try await dependencies.transactionAttachmentRepository.add(TransactionAttachment(
                    id: attachment.id,
                    transactionID: attachment.transactionID,
                    fileName: attachment.fileName,
                    mimeType: attachment.mimeType,
                    localRelativePath: stored.relativePath,
                    createdAt: attachment.createdAt
                ))
            } catch {
                // Keine Datei ohne Eintrag zurücklassen.
                try? service.delete(relativePath: stored.relativePath)
                throw error
            }
            lastRemoved = nil
            actionError = nil
            await load()
        } catch {
            actionError = String(localized: "Der Beleg konnte nicht wiederhergestellt werden.")
        }
    }

    /// Verwirft die Möglichkeit, das letzte Entfernen zurückzunehmen.
    func forgetRemoved() {
        lastRemoved = nil
    }

    /// Pfad der Belegdatei; `nil` mit sichtbarem Fehler, wenn sie fehlt.
    func existingFileURL(for attachment: TransactionAttachment) -> URL? {
        guard let service = try? service() else {
            actionError = String(localized: "Speicherort nicht verfügbar.")
            return nil
        }
        let url = service.absoluteURL(forRelativePath: attachment.localRelativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            actionError = String(localized: "Beleg-Datei wurde nicht gefunden.")
            return nil
        }
        return url
    }
}
