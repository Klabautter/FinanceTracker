import SwiftUI

/// Kanonische Designsprache der App. Ältere Auswahlwerte bleiben lesbar,
/// damit bestehende `UserDefaults`- und Codable-Daten ohne Migration auf das
/// gemeinsame Design abgebildet werden.
enum AppAppearance: String, CaseIterable, Identifiable, Codable, Sendable {
    case bento

    var id: String { rawValue }

    var displayName: String { "Bento" }

    var summary: String { String(localized: "Eine gemeinsame, adaptive Oberfläche mit klarer Typografie und ruhigen Systemflächen.") }

    static let storageKey = "appAppearance"
    static let fallback = AppAppearance.bento

    init(storedValue: String) {
        // classic, washi and elegant are legacy values. Unknown future values
        // also resolve safely to the current canonical design.
        self = AppAppearance(rawValue: storedValue) ?? .fallback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = AppAppearance(storedValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
