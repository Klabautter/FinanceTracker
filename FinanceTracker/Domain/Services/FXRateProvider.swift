import Foundation

/// P2 Live-FX: Abstraktion für EUR-Referenzkurse (1 Einheit → EUR).
///
/// Produkt-Semantik (#17/#19/#35):
/// - Fehlender Kurs = `nil` beim Konvertieren + Meldung über
///   `excludedCurrencies`, niemals 0 oder stiller Fallback-Kurs.
/// - Kurse sind immer positiv; nicht-positive Werte werden verworfen.
/// - Statische `CurrencyConverter.referenceEURRates` (29.08.2026) bleiben der
///   Fallback, wenn Live-Kurse fehlen.
struct FXRateSnapshot: Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        /// Frisch vom EZB-Feed.
        case live
        /// Gültiger Datei-Cache (innerhalb TTL).
        case cache
        /// Statische Kurse (29.08.2026), kein Netzwerk/Cache verfügbar.
        case fallback
    }

    /// Kurse: 1 Einheit der Währung in EUR (nur positive Werte).
    let eurPerUnit: [CurrencyCode: Decimal]
    /// Actual date of the quote sheet, distinct from the time we downloaded it.
    let quoteDate: Date?
    /// Time this rate set was retrieved. Static reference rates have no retrieval time.
    let fetchedAt: Date?
    let source: Source
    /// True when this rate set is beyond the provider's freshness window or has no live retrieval.
    let isStale: Bool
    /// A network refresh failed and these rates were retained as a best-effort estimate.
    let refreshFailed: Bool

    init(
        eurPerUnit: [CurrencyCode: Decimal],
        quoteDate: Date? = nil,
        fetchedAt: Date? = nil,
        source: Source,
        isStale: Bool = false,
        refreshFailed: Bool = false
    ) {
        self.eurPerUnit = eurPerUnit
        self.quoteDate = quoteDate
        self.fetchedAt = fetchedAt
        self.source = source
        self.isStale = isStale
        self.refreshFailed = refreshFailed
    }
}

protocol FXRateProvider: Sendable {
    /// Aktueller Snapshot (live → cache → fallback). Wirft nur bei
    /// Programmier-/IO-Fehlern, die kein Fallback zulassen; Netzwerkfehler
    /// führen zum Fallback-Snapshot, nicht zum Throw.
    func snapshot() async -> FXRateSnapshot
    /// Forces a provider refresh, bypassing a still-valid local cache.
    func refresh() async -> FXRateSnapshot
    /// Konverter aus dem aktuellen Snapshot (gleiche Pivot-Mathematik wie
    /// `CurrencyConverter`).
    func converter() async -> CurrencyConverter
}

extension FXRateProvider {
    func refresh() async -> FXRateSnapshot { await snapshot() }

    func converter() async -> CurrencyConverter {
        CurrencyConverter(eurPerUnit: await snapshot().eurPerUnit)
    }
}
