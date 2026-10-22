import Foundation

/// WP24: Typed Deep-Link-Routen für die Command Palette.
enum PaletteRoute: Equatable {
    case section(AppSection)
    case reviewQueue
    case settings
    case transaction(UUID)
    case account(UUID)
    case category(UUID)
    case tag(UUID)
    /// MacUX-Audit (Cashflow-Klick): Monats-Drilldown aus dem Dashboard-
    /// Cashflow-Chart in die gefilterte Transaktionsliste.
    case transactionsMonth(DateInterval)
    case transactionsScope(AnalyticsScope)
}
