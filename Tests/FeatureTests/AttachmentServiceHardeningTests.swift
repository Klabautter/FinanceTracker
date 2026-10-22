import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

/// WP31: Attachment-IO-Hardening: Limits, Copy statt RAM-Load,
/// Delete-Semantik, Kontrollfehler.
@MainActor
@Suite("AttachmentServiceHardening")
struct AttachmentServiceHardeningTests {

    private func makeService(
        maxBytes: Int = 1024 * 1024
    ) -> (AttachmentService, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("att-hardening-\(UUID().uuidString)", isDirectory: true)
        var limits = AttachmentService.Limits()
        limits.maxFileSize = maxBytes
        return (AttachmentService(attachmentsBaseDirectory: base, limits: limits), base)
    }

    private func writeFixture(_ base: URL, name: String, bytes: Data) -> URL {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent(name)
        try? bytes.write(to: url)
        return url
    }

    @Test("store(sourceURL:) kopiert die Datei ohne RAM-Load")
    func storeFromSourceURL() throws {
        let (service, base) = makeService()
        let source = writeFixture(base, name: "beleg.pdf", bytes: Data("fixture-bytes".utf8))
        let txnID = UUID()

        let stored = try service.store(
            sourceURL: source,
            fileName: "beleg.pdf",
            mimeType: "application/pdf",
            transactionID: txnID
        )

        #expect(stored.relativePath.hasPrefix("\(txnID.uuidString)/"))
        let storedBytes = try service.data(forRelativePath: stored.relativePath)
        #expect(storedBytes == Data("fixture-bytes".utf8))
    }

    @Test("Übergroße Datei wird vor dem Kopieren abgelehnt")
    func oversizedRejected() throws {
        let (service, base) = makeService(maxBytes: 8)
        let source = writeFixture(base, name: "gross.pdf", bytes: Data(repeating: 0x41, count: 100))

        #expect(throws: AttachmentService.AttachmentServiceError.fileTooLarge(maxBytes: 8)) {
            try service.store(
                sourceURL: source,
                fileName: "gross.pdf",
                mimeType: "application/pdf",
                transactionID: UUID()
            )
        }
    }

    @Test("Nicht unterstützter MIME-Typ wird abgelehnt")
    func unsupportedTypeRejected() throws {
        let (service, base) = makeService()
        let source = writeFixture(base, name: "virus.exe", bytes: Data("MZ".utf8))

        #expect(throws: AttachmentService.AttachmentServiceError.unsupportedMimeType("application/octet-stream")) {
            try service.store(
                sourceURL: source,
                fileName: "virus.exe",
                mimeType: "application/octet-stream",
                transactionID: UUID()
            )
        }
    }

    @Test("Delete entfernt die Datei; doppeltes Delete ist idempotent")
    func deleteSemantics() throws {
        let (service, base) = makeService()
        let stored = try service.store(
            data: Data("x".utf8),
            fileName: "beleg.png",
            mimeType: "image/png",
            transactionID: UUID()
        )
        #expect(FileManager.default.fileExists(atPath: service.absoluteURL(forRelativePath: stored.relativePath).path))

        try service.delete(relativePath: stored.relativePath)
        #expect(!FileManager.default.fileExists(atPath: service.absoluteURL(forRelativePath: stored.relativePath).path))
        try service.delete(relativePath: stored.relativePath) // kein Crash
    }

    @Test("defaultBaseDirectory ist throwing und zeigt ins App-Verzeichnis")
    func defaultBaseDirectoryThrowsInsteadOfCrash() throws {
        let url = try AttachmentService.defaultBaseDirectory()
        #expect(url.path.contains("FinanceTracker"))
        #expect(url.lastPathComponent == "Attachments")
    }

    @Test("Erlaubte MIME-Typen: PDF/PNG/JPEG/HEIC")
    func allowedTypes() throws {
        let (service, base) = makeService()
        for (name, mime, ext) in [
            ("a.pdf", "application/pdf", "pdf"),
            ("b.png", "image/png", "png"),
            ("c.jpg", "image/jpeg", "jpg"),
            ("d.heic", "image/heic", "heic")
        ] {
            let source = writeFixture(base, name: name, bytes: Data("x".utf8))
            let stored = try service.store(
                sourceURL: source,
                fileName: name,
                mimeType: mime,
                transactionID: UUID()
            )
            #expect(stored.relativePath.hasSuffix(ext))
        }
    }
}