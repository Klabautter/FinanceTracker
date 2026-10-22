import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Palette

/// Klare, ruhige Oberfläche mit eindeutiger Finanzsemantik: Grün heißt
/// Einnahme/Plus, Rot heißt Ausgabe/Minus/Überschreitung, Orange heißt
/// Achtung. Interaktion folgt der Akzentfarbe aus den macOS-Einstellungen.
/// Jede Farbe ist adaptiv (hell/dunkel) und wird ausschließlich hier definiert.
enum AppPalette {
    /// Arbeitsfläche hinter allen Inhalten.
    static let canvas = Color(light: 0xF4F4F6, dark: 0x161618)
    /// Inhaltskarten.
    static let card = Color(light: 0xFFFFFF, dark: 0x212124)
    /// Vertiefte Flächen (Eingaben, Hinweise, Chips).
    static let sunken = Color(light: 0xEEEEF1, dark: 0x2A2A2D)
    /// Hover/hervorgehobene Zeile.
    static let raised = Color(light: 0xF7F7F9, dark: 0x28282B)
    static let hairline = Color(light: 0x000000, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.08)

    /// Interaktion folgt der System-Akzentfarbe.
    static let brand = Color.accentColor

    static let positive = Color(light: 0x16A34A, dark: 0x34D17A)
    static let critical = Color(light: 0xE5383B, dark: 0xFF6161)
    static let warning = Color(light: 0xE07B00, dark: 0xFFAD33)
    static let information = Color(light: 0x2F6FEB, dark: 0x6AA5FF)

    /// Diagramme: Einnahmen grün, Ausgaben rot: Gewinn/Verlust auf einen Blick.
    static let chartIncome = positive
    static let chartExpense = critical
    static let chartForecast = Color(light: 0xA1A1AA, dark: 0x6B6B73)
}

extension Color {
    /// Adaptive Farbe aus zwei Hex-Werten.
    init(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
        #elseif os(iOS)
        self.init(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            return UIColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
        #else
        self.init(.sRGB, red: Double((light >> 16) & 0xFF) / 255, green: Double((light >> 8) & 0xFF) / 255, blue: Double(light & 0xFF) / 255, opacity: lightAlpha)
        #endif
    }
}

#if os(macOS)
private extension NSColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
#elseif os(iOS)
private extension UIColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
#endif

// MARK: - Geometry

/// Shared radii keep the interface consistent.
enum AppRadius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 8
    static let large: CGFloat = 12
    static let card: CGFloat = 14
    static let sheet: CGFloat = 14
    static let pill: CGFloat = 1_000
}

/// Layout values are semantic rather than screen-specific. Feature views can
/// compose these values without owning a second spacing system.
enum AppLayout {
    static let pageHorizontalPadding: CGFloat = 28
    static let pageVerticalPadding: CGFloat = AppSpacing.xl
    static let sectionSpacing: CGFloat = AppSpacing.xl
    static let contentSpacing: CGFloat = AppSpacing.l
    static let compactContentSpacing: CGFloat = AppSpacing.m
    static let cardPadding: CGFloat = 20
    static let controlMinimumHeight: CGFloat = 32
    static let metricMinimumWidth: CGFloat = 136
    /// Horizontal title/action layout only applies when the actual page
    /// content can provide this width; narrower windows stack the header.
    static let pageHeaderHorizontalMinimumWidth: CGFloat = 620
    static let filterBarHorizontalMinimumWidth: CGFloat = 560
    /// Shared content rules used by feature layouts as they adopt the shell.
    static let dashboardTwoColumnMinimumWidth: CGFloat = 1_280
    static let summaryMaximumWidth: CGFloat = 1_400
    static let formSheetIdealWidth: CGFloat = 520
    static let formSheetMaximumWidth: CGFloat = 640
}

// MARK: - Typography

/// SF Pro mit enger Laufweite für Titel und große Zahlen; Beträge setzen
/// zusätzlich `monospacedDigit()`. Keine Rounded-Schnitte.
enum AppTypography {
    static let pageTitle = Font.system(size: 26, weight: .bold)
    static let sheetTitle = Font.system(size: 17, weight: .semibold)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let eyebrow = Font.system(size: 10.5, weight: .medium)
    static let heroMetric = Font.system(size: 40, weight: .semibold)
    static let largeMetric = Font.system(size: 28, weight: .semibold)
    static let metric = Font.system(size: 21, weight: .semibold)
    static let compactMetric = Font.system(size: 15, weight: .semibold)
    static let amount = Font.system(size: 13, weight: .medium)
    static let label = Font.subheadline.weight(.medium)
    static let body = Font.body
    static let supporting = Font.callout
    static let metadata = Font.caption
    static let compactMetadata = Font.caption2
}

// MARK: - Tone

/// Meaning is expressed through a single semantic vocabulary.
enum AppTone: String, CaseIterable, Sendable {
    case neutral
    case accent
    case positive
    case warning
    case critical
    case information

    var foregroundColor: Color {
        switch self {
        case .neutral: .primary
        case .accent: AppPalette.brand
        case .positive: AppPalette.positive
        case .warning: AppPalette.warning
        case .critical: AppPalette.critical
        case .information: AppPalette.information
        }
    }

    /// Farbe für Flächen/Balken: `neutral` wird hier zum Markenakzent statt
    /// zu reinem Schwarz.
    var fillColor: Color {
        self == .neutral ? Color.secondary : foregroundColor
    }

    var defaultSystemImage: String {
        switch self {
        case .neutral: "circle"
        case .accent: "sparkles"
        case .positive: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .information: "info.circle.fill"
        }
    }

    var accessibilityPrefix: String {
        switch self {
        case .neutral: String(localized: "Status")
        case .accent: String(localized: "Hervorgehoben")
        case .positive: String(localized: "Erfolgreich")
        case .warning: String(localized: "Warnung")
        case .critical: String(localized: "Fehler")
        case .information: String(localized: "Information")
        }
    }
}

// MARK: - Surfaces

/// Content surfaces stay solid. Material is reserved for controls that
/// functionally float above content; Liquid Glass remains in
/// `floatingControlSurface` and is never used by these content roles.
enum AppSurface: Sendable {
    case plain
    /// Inhaltskarte mit Haarlinie und sehr weichem Schatten.
    case groupedContent
    /// Vertiefte Fläche innerhalb einer Karte.
    case insetContent
    case functionalControl
}

private struct AppSurfaceModifier: ViewModifier {
    let surface: AppSurface
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch surface {
        case .plain:
            content
        case .groupedContent:
            content
                .background(
                    shape
                        .fill(AppPalette.card)
                        .shadow(color: Color.black.opacity(0.05), radius: 6, y: 2)
                        .overlay { shape.strokeBorder(AppPalette.hairline, lineWidth: 1) }
                )
        case .insetContent:
            content
                .background(shape.fill(AppPalette.sunken))
        case .functionalControl:
            content
                .background(shape.fill(.regularMaterial))
        }
    }
}

extension View {
    func workspaceCanvas() -> some View {
        background(AppPalette.canvas)
    }

    func appSurface(
        _ surface: AppSurface,
        cornerRadius: CGFloat = AppRadius.card
    ) -> some View {
        modifier(AppSurfaceModifier(surface: surface, cornerRadius: cornerRadius))
    }

    /// Standard-Inhaltskarte mit Innenabstand.
    func financeCard(padding: CGFloat = AppLayout.cardPadding, cornerRadius: CGFloat = AppRadius.card) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .appSurface(.groupedContent, cornerRadius: cornerRadius)
    }

    /// Native `Form`/`List`-Inhalte auf der Arbeitsfläche statt auf dem
    /// Standardweiß, gruppierte Sektionen wirken dadurch wie Karten.
    func financeFormStyle() -> some View {
        self
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(AppPalette.canvas)
    }

    /// Kleine Versalien-Überschrift („Eyebrow").
    func eyebrowStyle(_ color: Color = .secondary) -> some View {
        self
            .font(AppTypography.eyebrow)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(color)
    }
}
