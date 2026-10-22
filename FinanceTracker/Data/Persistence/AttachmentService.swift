import Foundation

/// Attachments (Roadmap #143–148 / WP31): Dateien liegen unter
/// `Application Support/FinanceTracker/Attachments/<txnID>/<id>.<ext>`,
/// Metadaten in SwiftData (#145/#242-33).
///
/// WP31-Hardening:
/// - `store(sourceURL:)` kopiert die Datei (FileManager.copyItem) statt sie
///   vollständig in den RAM zu laden.
/// - Größen- und MIME-Validierung vor dem Kopieren (kontrollierte Fehler).
/// - Alle IO-Methoden sind synchron und stateless: Aufrufer müssen sie
///   off-main ausführen (View-Pfad: Task.detached).
/// - `defaultBaseDirectory()` ist throwing (kein Force-unwrap, §220).
struct AttachmentService: Sendable {
    struct Limits: Sendable {
        /// Produktentscheidung (§216): 25 MB pro Anhang; PDF/JPEG/PNG/HEIC.
        var maxFileSize: Int = 25 * 1024 * 1024
        var allowedMIMETypes: Set<String> = [
            "application/pdf",
            "image/png",
            "image/jpeg",
            "image/heic"
        ]

        static let `default` = Limits()
    }

    enum AttachmentServiceError: Error, Equatable {
        case applicationSupportUnavailable
        case fileTooLarge(maxBytes: Int)
        case unsupportedMimeType(String)
        case sourceFileUnreadable(String)
    }

    let attachmentsBaseDirectory: URL
    let limits: Limits

    init(attachmentsBaseDirectory: URL, limits: Limits = .default) {
        self.attachmentsBaseDirectory = attachmentsBaseDirectory
        self.limits = limits
    }

    /// §220: Throwing statt Force-unwrap.
    static func defaultBaseDirectory() throws -> URL {
        // Über `AppDataDirectory`: isolierte Testläufe schreiben nie in den
        // echten App-Ordner.
        guard let root = AppDataDirectory.root() else {
            throw AttachmentServiceError.applicationSupportUnavailable
        }
        return root.appendingPathComponent("Attachments", isDirectory: true)
    }

    /// WP31 (§214): Kopiert die Quelldatei OHNE vollständiges RAM-Load
    /// (FileManager.copyItem) und liefert die relativen Pfadkomponenten.
    func store(
        sourceURL: URL,
        fileName: String,
        mimeType: String,
        transactionID: UUID
    ) throws -> (relativePath: String, attachmentID: UUID) {
        try validate(mimeType: mimeType, sourceURL: sourceURL)

        let attachmentID = UUID()
        let fileExtension = sanitizedExtension(from: fileName, mimeType: mimeType)
        let transactionDirectory = attachmentsBaseDirectory
            .appendingPathComponent(transactionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)

        let fileURL = transactionDirectory.appendingPathComponent("\(attachmentID.uuidString).\(fileExtension)")

        var didCopy = false
        defer {
            // Halbfertige Kopie bei Fehler entfernen (kein Orphan).
            if didCopy == false {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        try FileManager.default.copyItem(at: sourceURL, to: fileURL)
        didCopy = true

        return (
            relativePath: "\(transactionID.uuidString)/\(attachmentID.uuidString).\(fileExtension)",
            attachmentID: attachmentID
        )
    }

    /// In-Memory-Variante (Tests, kleine Payloads), mit denselben Limits.
    func store(
        data: Data,
        fileName: String,
        mimeType: String,
        transactionID: UUID
    ) throws -> (relativePath: String, attachmentID: UUID) {
        try validate(mimeType: mimeType, dataCount: data.count)

        let attachmentID = UUID()
        let fileExtension = sanitizedExtension(from: fileName, mimeType: mimeType)
        let transactionDirectory = attachmentsBaseDirectory
            .appendingPathComponent(transactionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)

        let fileURL = transactionDirectory.appendingPathComponent("\(attachmentID.uuidString).\(fileExtension)")
        try data.write(to: fileURL, options: .atomic)

        return (
            relativePath: "\(transactionID.uuidString)/\(attachmentID.uuidString).\(fileExtension)",
            attachmentID: attachmentID
        )
    }

    func absoluteURL(forRelativePath relativePath: String) -> URL {
        attachmentsBaseDirectory.appendingPathComponent(relativePath)
    }

    func delete(relativePath: String) throws {
        let url = absoluteURL(forRelativePath: relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func data(forRelativePath relativePath: String) throws -> Data {
        try Data(contentsOf: absoluteURL(forRelativePath: relativePath))
    }

    // MARK: - Validation (§216/§217)

    private func validate(mimeType: String, sourceURL: URL? = nil, dataCount: Int? = nil) throws {
        guard limits.allowedMIMETypes.contains(mimeType) else {
            throw AttachmentServiceError.unsupportedMimeType(mimeType)
        }

        let byteCount: Int
        if let sourceURL {
            let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey])
            // §217: Größe VOR dem Kopieren prüfen.
            guard let size = values?.fileSize else {
                throw AttachmentServiceError.sourceFileUnreadable(sourceURL.lastPathComponent)
            }
            byteCount = size
        } else {
            byteCount = dataCount ?? 0
        }

        guard byteCount <= limits.maxFileSize else {
            throw AttachmentServiceError.fileTooLarge(maxBytes: limits.maxFileSize)
        }
    }

    private func sanitizedExtension(from fileName: String, mimeType: String) -> String {
        let ext = (fileName as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !ext.isEmpty, ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return ext
        }
        switch mimeType {
        case "application/pdf": return "pdf"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/heic": return "heic"
        default: return "dat"
        }
    }
}
