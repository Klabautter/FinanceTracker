import Foundation
import SwiftData

/// V16-Sidecar: Anzeige-Einstellung je Konto (1:1 über `accountID`), nur
/// für ausgeblendete Konten. Eigene Tabelle statt neuer Spalte auf
/// `SDAccountSettingsEntity`, damit V15 hash-stabil bleibt.
@Model
final class SDAccountVisibilityEntity {
    @Attribute(.unique) var accountID: UUID
    /// „In der Kontenliste ausblenden": nur die Liste, Buchungen und Stand
    /// bleiben überall sonst erhalten.
    var hiddenInList: Bool
    var updatedAt: Date

    init(accountID: UUID, hiddenInList: Bool, updatedAt: Date = Date()) {
        self.accountID = accountID
        self.hiddenInList = hiddenInList
        self.updatedAt = updatedAt
    }
}
