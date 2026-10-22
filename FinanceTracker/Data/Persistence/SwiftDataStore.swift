import Foundation
import SwiftData

/// WP1 (§10): Explizite Store-Lokalisierung statt impliziter Init-Varianten.
///
/// - `live`:    Production-Store im Application Support.
/// - `inMemory`: Tests/Previews.
/// - `url`:     Expliziter Pfad, UI-Tests nutzen pro Launch eine isolierte
///              Temp-Store-Datei, damit der User-Store nie berührt wird (§9).
enum StoreLocation: Sendable {
    case live
    case inMemory
    case url(URL)
}

final class SwiftDataStore {
    let container: ModelContainer

    private static var schema: Schema {
        Schema(FinanceTrackerSchemaV13.models)
    }

    /// Eigener, app-spezifischer Store-Pfad: Der SwiftData-Defaultname
    /// „default.store" wird von beliebigen anderen Apps genutzt: Kollisionen
    /// dort beschädigen die Erkennung („unknown model version").
    static func liveStoreURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent("FinanceTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("FinanceTracker.store")
    }

    init(location: StoreLocation) throws {
        let configuration: ModelConfiguration
        switch location {
        case .live:
            configuration = ModelConfiguration(url: Self.liveStoreURL())
        case .inMemory:
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        case .url(let url):
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(url: url)
        }
        container = try ModelContainer(
            for: Self.schema,
            migrationPlan: FinanceTrackerMigrationPlan.self,
            configurations: [configuration]
        )
    }

    /// Kompatibilitäts-Init (bestehende Tests/Previews).
    convenience init(inMemory: Bool = false) throws {
        try self.init(location: inMemory ? .inMemory : .live)
    }

    /// Kompatibilitäts-Init: Bestehenden Store an konkretem Pfad öffnen.
    convenience init(url: URL) throws {
        try self.init(location: .url(url))
    }
}
