import Foundation
import SwiftData

/// V14-Sidecar: zuletzt von Bank oder Datei gemeldeter Kontostand je Konto
/// (1:1 über `accountID`). Eigene Tabelle wie beim Anfangsbestand, damit
/// V1–V13 hash-stabil bleiben. Betrag als Dezimal-String (strikt, #23).
@Model
final class SDAccountReportedBalanceEntity {
    @Attribute(.unique) var accountID: UUID
    var amountValue: String
    var currencyRaw: String
    /// Zeitpunkt, zu dem der Stand galt (Bankabruf oder Datum der Zeile).
    var asOf: Date
    var sourceRaw: String
    var updatedAt: Date

    init(accountID: UUID, amountValue: String, currencyRaw: String, asOf: Date, sourceRaw: String, updatedAt: Date) {
        self.accountID = accountID
        self.amountValue = amountValue
        self.currencyRaw = currencyRaw
        self.asOf = asOf
        self.sourceRaw = sourceRaw
        self.updatedAt = updatedAt
    }
}

extension SDAccountReportedBalanceEntity {
    convenience init(accountID: UUID, balance: ReportedBalance) {
        self.init(
            accountID: accountID,
            amountValue: NSDecimalNumber(decimal: balance.amount.amount).stringValue,
            currencyRaw: balance.amount.currency.rawValue,
            asOf: balance.asOf,
            sourceRaw: balance.source.rawValue,
            updatedAt: Date()
        )
    }

    func update(_ balance: ReportedBalance) {
        amountValue = NSDecimalNumber(decimal: balance.amount.amount).stringValue
        currencyRaw = balance.amount.currency.rawValue
        asOf = balance.asOf
        sourceRaw = balance.source.rawValue
        updatedAt = Date()
    }

    /// Strikt (#23): korrupte Werte werden nicht als 0 oder Standardquelle
    /// maskiert.
    func toDomain() throws -> ReportedBalance {
        guard let amount = Decimal(string: amountValue), !amount.isNaN else {
            throw PersistenceDecodingError.invalidAmount(field: "reportedBalance", raw: amountValue)
        }
        guard let source = ReportedBalance.Source(rawValue: sourceRaw) else {
            throw PersistenceDecodingError.unknownEnum(field: "reportedBalanceSource", raw: sourceRaw)
        }
        let currency = CurrencyCode(currencyRaw)
        return ReportedBalance(amount: Money(amount: amount, currency: currency), asOf: asOf, source: source)
    }
}
