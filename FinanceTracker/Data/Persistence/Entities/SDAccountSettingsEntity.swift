import Foundation
import SwiftData

/// V15-Sidecar: Nutzer-Einstellungen je Konto (1:1 über `accountID`), nur
/// für Konten mit abweichender Einstellung. Eigene Tabelle statt neuer
/// Spalten auf `SDAccountEntity`, damit V1–V14 hash-stabil bleiben (Muster
/// wie `SDAccountOpeningBalanceEntity`).
@Model
final class SDAccountSettingsEntity {
    @Attribute(.unique) var accountID: UUID
    /// „Nicht zum Gesamtstand zählen": der Stand bleibt sichtbar, fließt
    /// aber nicht in Gesamtstand und Reichweite ein.
    var excludedFromTotal: Bool
    var updatedAt: Date

    init(accountID: UUID, excludedFromTotal: Bool, updatedAt: Date = Date()) {
        self.accountID = accountID
        self.excludedFromTotal = excludedFromTotal
        self.updatedAt = updatedAt
    }
}
