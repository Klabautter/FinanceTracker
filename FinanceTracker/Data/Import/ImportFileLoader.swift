import Foundation

struct ImportFileLoader: Sendable {
    func load(at url: URL) async throws -> ImportFile {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? Int, size > ImportLimits.maxFileSizeBytes {
            throw ImportError.parsingFailed(
                stage: "fileValidation",
                reason: String(localized: "Die Datei ist zu groß (Maximum: \(ImportLimits.maxFileSizeBytes / 1_024 / 1_024) MB).")
            )
        }

        let wasScoped = url.startAccessingSecurityScopedResource()
        defer { if wasScoped { url.stopAccessingSecurityScopedResource() } }

        let fileData = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value

        return ImportFile(fileName: url.lastPathComponent, data: fileData)
    }
}
