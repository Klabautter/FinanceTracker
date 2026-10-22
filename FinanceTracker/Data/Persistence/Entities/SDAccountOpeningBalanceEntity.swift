import Foundation
import SwiftData

/// V13-Sidecar: Anfangsbestand je Konto (1:1 über `accountID`), nur für
/// Konten, bei denen der Nutzer ihn erfasst hat: Bargeld, Konten ohne
/// Anbindung. Eigene Tabelle statt neuer Spalten auf `SDAccountEntity`,
/// damit V1–V12 hash-stabil bleiben (keine Duplicate-Checksums; Muster wie
/// `SDBudgetGoalEntity`). Betrag als Dezimal-String (strikt, #23).
@Model
final class SDAccountOpeningBalanceEntity {
    @Attribute(.unique) var accountID: UUID
    var amountValue: String
    /// Stand zu Beginn dieses Tages; nil = alle Bewegungen zählen.
    var date: Date?
    var updatedAt: Date

    init(accountID: UUID, amountValue: String, date: Date?, updatedAt: Date) {
        self.accountID = accountID
        self.amountValue = amountValue
        self.date = date
        self.updatedAt = updatedAt
    }
}

extension SDAccountOpeningBalanceEntity {
    convenience init(accountID: UUID, amount: Decimal, date: Date?) {
        self.init(
            accountID: accountID,
            amountValue: NSDecimalNumber(decimal: amount).stringValue,
            date: date,
            updatedAt: Date()
        )
    }

    func update(amount: Decimal, date: Date?) {
        amountValue = NSDecimalNumber(decimal: amount).stringValue
        self.date = date
        updatedAt = Date()
    }

    /// Strikt (#23): ein korrupter Betrag wird nicht als 0 maskiert.
    func decimalAmount() throws -> Decimal {
        guard let amount = Decimal(string: amountValue), !amount.isNaN else {
            throw PersistenceDecodingError.invalidAmount(field: "openingBalance", raw: amountValue)
        }
        return amount
    }
}
