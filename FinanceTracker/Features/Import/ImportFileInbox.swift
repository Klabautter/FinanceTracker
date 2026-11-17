import Foundation
import Observation

/// Eingangsfach für eine Datei, die von außen kommt: aufs Fenster oder aufs
/// Dock-Symbol gezogen oder über „Öffnen mit" (Roadmap 2.3). Die App legt
/// die Datei hier ab; der Hauptbereich nimmt sie heraus und öffnet den
/// Import. So geht auch eine Datei nicht verloren, die die App erst
/// startet, während die Datenbank noch öffnet. Eine Instanz pro App,
/// über das Environment gereicht (kein Singleton).
@MainActor
@Observable
final class ImportFileInbox {
    /// Die wartende Datei mit eigener Identität, damit dieselbe Datei
    /// zweimal hintereinander ankommen kann.
    struct PendingFile: Identifiable, Equatable {
        let id = UUID()
        let url: URL
    }

    private(set) var pending: PendingFile?

    /// Dateiendungen, die der Import lesen kann.
    nonisolated static let supportedExtensions: Set<String> = ["csv", "txt", "tsv", "xlsx", "pdf"]

    nonisolated static func isImportFile(_ url: URL) -> Bool {
        url.isFileURL && supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Nimmt die Datei an, wenn der Import sie lesen kann.
    @discardableResult
    func offer(_ url: URL) -> Bool {
        guard Self.isImportFile(url) else { return false }
        pending = PendingFile(url: url)
        return true
    }

    /// Erste lesbare Datei aus einer Gruppe gezogener Dateien.
    @discardableResult
    func offer(firstOf urls: [URL]) -> Bool {
        guard let url = urls.first(where: Self.isImportFile) else { return false }
        return offer(url)
    }

    /// Nimmt die wartende Datei heraus.
    func take() -> PendingFile? {
        defer { pending = nil }
        return pending
    }
}
