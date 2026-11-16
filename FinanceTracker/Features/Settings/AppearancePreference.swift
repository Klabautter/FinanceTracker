import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Erscheinungsbild der App: wie das System, immer hell oder immer dunkel.
/// Gesetzt über `NSApp.appearance`, das Fensterrahmen UND Inhalt erfasst;
/// `preferredColorScheme` am Fenster-Root hängt unter macOS 26 die
/// Fensterdarstellung auf (siehe FinanceTrackerApp).
enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let defaultsKey = "appearancePreference"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "Wie System")
        case .light: String(localized: "Hell")
        case .dark: String(localized: "Dunkel")
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AppearancePreference {
        defaults.string(forKey: defaultsKey).flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    @MainActor
    func apply() {
        #if os(macOS)
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        #endif
    }
}
