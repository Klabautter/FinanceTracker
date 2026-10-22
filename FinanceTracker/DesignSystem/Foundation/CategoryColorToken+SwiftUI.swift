import SwiftUI

/// Kategoriefarben: klar unterscheidbar für Symbole und Diagramme, auf
/// hellem und dunklem Grund abgestimmt.
extension CategoryColorToken {
    var color: Color {
        switch self {
        case .blue: Color(light: 0x2F7CF6, dark: 0x5B9BFF)
        case .green: Color(light: 0x22A35A, dark: 0x3FD17F)
        case .orange: Color(light: 0xF08A24, dark: 0xFFA24D)
        case .purple: Color(light: 0x9B5DE5, dark: 0xB887FF)
        case .red: Color(light: 0xE5484D, dark: 0xFF6B6B)
        case .teal: Color(light: 0x14A3A3, dark: 0x3CCFCF)
        case .yellow: Color(light: 0xD4A017, dark: 0xF5C542)
        case .indigo: Color(light: 0x5E5CE6, dark: 0x8583FF)
        case .gray: Color(light: 0x8A8A93, dark: 0x9E9EA6)
        }
    }

    var localizedName: String {
        switch self {
        case .blue: String(localized: "Blau")
        case .green: String(localized: "Grün")
        case .orange: String(localized: "Orange")
        case .purple: String(localized: "Violett")
        case .red: String(localized: "Rot")
        case .teal: String(localized: "Türkis")
        case .yellow: String(localized: "Gelb")
        case .indigo: String(localized: "Indigo")
        case .gray: String(localized: "Grau")
        }
    }
}
