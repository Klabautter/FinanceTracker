import Foundation

/// L10n-Muster (P2-Anbruch, kein Big-Bang): Kern-Strings nutzen
/// `String(localized:comment:)`; die Compiler-Extraction trägt sie in
/// `Resources/Localizable.xcstrings` ein (Development Language de).
/// Restliche ~185 hartcodierte UI-Strings folgen demselben Muster
/// schrittweise (Sidebar/Toolbar/Settings zuerst, Detail-Texte später).
enum AppSection: String, Hashable, Identifiable, CaseIterable {
    case overview
    case transactions
    case analytics
    case budgets
    case pockets
    case accounts
    case categories
    case recurring

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: String(localized: "Übersicht", comment: "Sidebar-Titel: Übersichts-Sektion")
        case .transactions: String(localized: "Transaktionen", comment: "Sidebar-Titel: Transaktionsliste")
        case .analytics: String(localized: "Analyse", comment: "Sidebar-Titel: Analyse-Sektion")
        case .budgets: String(localized: "Budgets", comment: "Sidebar-Titel: Budgets")
        case .pockets: String(localized: "Sammlungen", comment: "Sidebar-Titel: zeitlich begrenzte Transaktionssammlungen")
        case .accounts: String(localized: "Konten & Verbindungen", comment: "Sidebar-Titel: Konten und Datenquellenverbindungen")
        case .categories: String(localized: "Kategorien & Regeln", comment: "Sidebar-Titel: Kategorien und Regeln")
        case .recurring: String(localized: "Wiederkehrend", comment: "Sidebar-Titel: wiederkehrende Buchungen")
        }
    }

    /// Stabiler, nicht lokalisierter Name für Accessibility-Identifier
    /// (UI-Tests adressieren `sidebar-<Name>` unabhängig von der Sprache).
    var identifierName: String {
        switch self {
        case .overview: "Übersicht"
        case .transactions: "Transaktionen"
        case .analytics: "Analyse"
        case .budgets: "Budgets"
        case .pockets: "Sammlungen"
        case .accounts: "Konten & Verbindungen"
        case .categories: "Kategorien & Regeln"
        case .recurring: "Wiederkehrend"
        }
    }

    var sidebarTitle: String {
        switch self {
        case .accounts: String(localized: "Konten", comment: "Sidebar-Titel (kurz): Konten")
        case .categories: String(localized: "Kategorien", comment: "Sidebar-Titel (kurz): Kategorien")
        default: title
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .transactions: "list.bullet.rectangle"
        case .analytics: "chart.pie"
        case .budgets: "chart.bar"
        case .pockets: "square.stack.3d.up"
        case .accounts: "building.columns"
        case .categories: "square.grid.3x1.folder.badge.plus"
        case .recurring: "calendar.badge.clock"
        }
    }
}

/// P0: Sidebar-Gruppierung als testbare Quelle (statt Inline-Arrays in der
/// View); MacRootView rendert diese Gruppen 1:1.
struct SidebarGroup: Hashable, Sendable {
    let title: String
    let sections: [AppSection]
}

extension AppSection {
    static var sidebarGroups: [SidebarGroup] {
        [
            SidebarGroup(title: String(localized: "Alltag", comment: "Sidebar-Gruppe: alltägliche Bereiche"), sections: [.overview, .transactions, .analytics]),
            SidebarGroup(title: String(localized: "Planung", comment: "Sidebar-Gruppe: Planung"), sections: [.budgets, .recurring]),
            SidebarGroup(title: String(localized: "Organisation", comment: "Sidebar-Gruppe: persönliche Ordnung"), sections: [.pockets, .categories]),
            SidebarGroup(title: String(localized: "Daten", comment: "Sidebar-Gruppe: Konten und Verbindungen"), sections: [.accounts]),
        ]
    }

    /// ⌘1…⌘9 wechseln den Bereich in Sidebar-Reihenfolge (macOS-Konvention
    /// bei fester Seitenleiste); mehr als neun Einträge bekommen keinen Kurzbefehl.
    static var shortcutSections: [AppSection] {
        Array(sidebarGroups.flatMap(\.sections).prefix(9))
    }
}

/// Hält den aktuellen und den zuletzt geöffneten Bereich im macOS-
/// Detailbereich gemountet, damit der Wechsel zwischen beiden keine
/// Tabellenfilter, Auswahl oder Formularzustände verwirft.
///
/// Bewusst nicht alle besuchten Bereiche: Jeder gemountete Bereich wird bei
/// jeder Größenänderung mitvermessen: mit allen acht war der Hauptthread
/// beim Ein-/Ausblenden der Seitenleiste voll ausgelastet (Instruments:
/// ~3 900 statt ~1 650 Samples pro sechs Umschaltungen).
struct AppSectionNavigationState: Equatable {
    static let mountedSectionLimit = 2

    private(set) var selection: AppSection = .overview
    /// Zuletzt geöffnete Bereiche, neuester zuerst.
    private(set) var recentSections: [AppSection] = [.overview]

    var mountedSections: [AppSection] {
        AppSection.allCases.filter(recentSections.contains)
    }

    mutating func select(_ section: AppSection) {
        selection = section
        recentSections.removeAll { $0 == section }
        recentSections.insert(section, at: 0)
        if recentSections.count > Self.mountedSectionLimit {
            recentSections.removeLast(recentSections.count - Self.mountedSectionLimit)
        }
    }
}
