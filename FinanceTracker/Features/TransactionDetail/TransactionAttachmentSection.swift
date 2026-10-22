import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import QuickLook
#endif

/// Belege/Attachments (Roadmap #143–148): Datei-Import (PDF/Bilder),
/// Liste, Löschen. Dateien im Dateisystem, Metadaten in SwiftData.
/// WP16 (§114-118): iOS öffnet Belege über QuickLook-Preview, kein
/// toter Button.
struct TransactionAttachmentSection: View {
    let transaction: Transaction
    let dependencies: AppDependencies

    @State private var attachments: [TransactionAttachment] = []
    @State private var showsImporter = false
    @State private var errorMessage: String?
    @State private var isLoading = false
    /// WP16: Für die QuickLook-Preview ausgewählte Datei (iOS).
    @State private var previewURL: URL?

    private var attachmentService: AttachmentService {
        let baseDirectory = (try? AttachmentService.defaultBaseDirectory())
            ?? FileManager.default.temporaryDirectory
        return AttachmentService(attachmentsBaseDirectory: baseDirectory)
    }

    var body: some View {
        Section("Belege") {
            if isLoading {
                ProgressView()
            } else if attachments.isEmpty {
                Button {
                    showsImporter = true
                } label: {
                    Label("Beleg hinzufügen (PDF, Bild)…", systemImage: "paperclip")
                }
            } else {
                ForEach(attachments) { attachment in
                    HStack {
                        Label(attachment.fileName, systemImage: icon(for: attachment.mimeType))
                            .lineLimit(1)
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
                            Task { await delete(attachment) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Beleg \(attachment.fileName) löschen")
                        .help("Beleg löschen")
                    }
                }

                Button {
                    showsImporter = true
                } label: {
                    Label("Beleg hinzufügen…", systemImage: "plus")
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AppPalette.critical)
            }
        }
        .task(id: transaction.id) {
            attachments = []
            previewURL = nil
            errorMessage = nil
            await load(transactionID: transaction.id)
        }
        #if os(iOS)
        // WP16 (§115): QuickLook-Preview für PDF/Bilder.
        .quickLookPreview($previewURL)
        #endif
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.pdf, .png, .jpeg, UTType(filenameExtension: "heic") ?? .image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let transactionID = transaction.id
                Task { await importFile(url, transactionID: transactionID) }
            case .failure(let error):
                errorMessage = String(localized: "Datei konnte nicht gelesen werden: \(error.localizedDescription)")
            }
        }
    }

    private func icon(for mimeType: String) -> String {
        switch mimeType {
        case "application/pdf": "doc.richtext"
        case let m where m.hasPrefix("image/"): "photo"
        default: "paperclip"
        }
    }

    private func load(transactionID: Transaction.ID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await dependencies.transactionAttachmentRepository.attachments(
                transactionID: transactionID
            )
            guard !Task.isCancelled, transaction.id == transactionID else { return }
            attachments = loaded
        } catch {
            guard transaction.id == transactionID else { return }
            errorMessage = String(localized: "Belege konnten nicht geladen werden.")
        }
    }

    private func importFile(_ sourceURL: URL, transactionID: Transaction.ID) async {
        let mimeType = mimeType(for: sourceURL)
        do {
            let secured = sourceURL.startAccessingSecurityScopedResource()
            defer { if secured { sourceURL.stopAccessingSecurityScopedResource() } }

            // WP31 (§214/§215): Copy statt RAM-Load, IO off-main.
            let service = attachmentService
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
            await load(transactionID: transactionID)
        } catch let error as AttachmentService.AttachmentServiceError {
            switch error {
            case .fileTooLarge(let maxBytes):
                errorMessage = String(localized: "Die Datei ist zu groß. Maximal \(maxBytes / 1024 / 1024) MB.")
            case .unsupportedMimeType(let mime):
                errorMessage = String(localized: "Dateityp nicht unterstützt (\(mime)). Erlaubt: PDF, PNG, JPEG, HEIC.")
            case .sourceFileUnreadable(let name):
                errorMessage = String(localized: "Datei konnte nicht gelesen werden: \(name).")
            case .applicationSupportUnavailable:
                errorMessage = String(localized: "Speicherort nicht verfügbar.")
            }
        } catch {
            errorMessage = String(localized: "Beleg konnte nicht gespeichert werden.")
        }
    }

    /// WP31 (§218): Datei zuerst löschen; schlägt das fehl, werden die
    /// Metadaten BEHALTEN und der Fehler gemeldet (kein stiller Verlust).
    private func delete(_ attachment: TransactionAttachment) async {
        let transactionID = attachment.transactionID
        do {
            let service = attachmentService
            let relativePath = attachment.localRelativePath
            try await Task.detached(priority: .userInitiated) {
                try service.delete(relativePath: relativePath)
            }.value
            try await dependencies.transactionAttachmentRepository.delete(id: attachment.id)
            await load(transactionID: transactionID)
        } catch {
            errorMessage = String(localized: "Beleg-Datei konnte nicht entfernt werden. Eintrag bleibt erhalten.")
        }
    }

    private func open(_ attachment: TransactionAttachment) {
        let url = attachmentService.absoluteURL(forRelativePath: attachment.localRelativePath)
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        // WP16 (§115/§117): Interne lokale Datei: QuickLook benötigt keine
        // Security-Scoped-Permission. Fehlende Datei → sichtbarer Fehler.
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = String(localized: "Beleg-Datei wurde nicht gefunden.")
            return
        }
        previewURL = url
        #endif
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "heic": "image/heic"
        default: "application/octet-stream"
        }
    }
}
