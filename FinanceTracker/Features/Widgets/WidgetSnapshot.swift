import Foundation
#if os(macOS)
import Security
#endif

/// Was die Widgets zeigen (Roadmap 10.4): ein kleiner, fertig berechneter
/// Stand, den die App in den gemeinsamen App-Group-Ordner schreibt. Das
/// Widget rechnet nichts selbst und liest keine Datenbank. Beträge bleiben
/// `Decimal` (AGENTS.md Regel 3). Diese Datei gehört zur App und zur
/// Widget-Erweiterung.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    struct BudgetLine: Codable, Equatable, Sendable, Identifiable {
        var id: UUID
        var name: String
        var systemIconName: String
        var spent: Decimal
        var limit: Decimal
        var currency: String

        var fraction: Double {
            guard limit > 0 else { return 0 }
            return NSDecimalNumber(decimal: spent / limit).doubleValue
        }
    }

    /// Version des Formats; ein Widget zeigt einen unbekannten Stand nicht.
    static let formatVersion = 1

    var formatVersion: Int = WidgetSnapshot.formatVersion
    var updatedAt: Date
    var currency: String
    var monthSpending: Decimal
    /// Prognose bis Monatsende; `nil`, wenn Daten dafür fehlen.
    var availableUntilMonthEnd: Decimal?
    var budgets: [BudgetLine]
    /// Privatsphäre-Modus der App: Das Widget zeigt dann keine Beträge.
    var hidesAmounts: Bool
}

/// Lesen und Schreiben des Snapshots im App-Group-Ordner.
struct WidgetSnapshotStore: Sendable {
    static let fileName = "widget-snapshot.json"
    /// Info.plist-Schlüssel mit der App-Group-Kennung (Team-ID-Präfix wird
    /// beim Signieren eingesetzt).
    static let appGroupInfoKey = "FTAppGroupIdentifier"

    let directory: URL

    /// Der gemeinsame Ordner von App und Widget; `nil` ohne App-Group-
    /// Berechtigung (z. B. selbst signierte Debug-Builds ohne Team-ID).
    static func shared(bundle: Bundle = .main) -> WidgetSnapshotStore? {
        guard let identifier = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
              !identifier.isEmpty, !identifier.hasPrefix("$("),
              processHasAppGroup(identifier),
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else { return nil }
        return WidgetSnapshotStore(directory: url)
    }

    /// Nur mit tatsächlich signierter App-Group: macOS liefert den Pfad
    /// auch ohne Berechtigung, ein Zugriff darauf kann dann eine
    /// Systemabfrage auslösen. Ohne Berechtigung schreibt die App nichts.
    private static func processHasAppGroup(_ identifier: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String] else { return false }
        return groups.contains(identifier)
        #else
        return true
        #endif
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func write(_ snapshot: WidgetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    /// `nil`, wenn es keinen oder einen unlesbaren Stand gibt; das Widget
    /// zeigt dann einen Hinweis statt erfundener Zahlen (Regel 17).
    func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.formatVersion == WidgetSnapshot.formatVersion else { return nil }
        return snapshot
    }
}
