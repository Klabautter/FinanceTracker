import Foundation
import SwiftData

/// V12-Sidecar für Splitwise-light-Anteile (P2, #27/#11).
///
/// User-Metadaten nach Vorbild `SDBudgetGoalEntity` (V11): Die Transaktion
/// selbst bleibt Provider-Fakt, nur die Aufteilung ist User-Besitz (wie
/// `TransactionAnnotation`). Kein Parallelmodell (#11): Die Zeile wird
/// immer in `SharedExpenseShare` gemappt.
///
/// Je Transaktion N Zeilen (anteilig): Zahler (`paidBy`), Schuldner
/// (`owedBy`), Anteil > 0 in `shareCurrencyRaw`, `settled`-Flag.
/// Währungen werden nie vermischt (#19/#35): Trennung übernimmt der
/// `GroupExpenseResolver` je Währung.
@Model
final class SDSharedExpenseShareEntity {
    @Attribute(.unique) var id: UUID
    var transactionID: UUID
    var paidBy: String
    var owedBy: String
    /// Anteil als Dezimal-String (strikt, #23: kein 0-Masking).
    var shareAmountValue: String
    var shareCurrencyRaw: String
    var settled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        transactionID: UUID,
        paidBy: String,
        owedBy: String,
        shareAmountValue: String,
        shareCurrencyRaw: String,
        settled: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.transactionID = transactionID
        self.paidBy = paidBy
        self.owedBy = owedBy
        self.shareAmountValue = shareAmountValue
        self.shareCurrencyRaw = shareCurrencyRaw
        self.settled = settled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension SDSharedExpenseShareEntity {
    convenience init(from share: SharedExpenseShare) {
        self.init(
            id: share.id,
            transactionID: share.transactionID,
            paidBy: share.paidBy,
            owedBy: share.owedBy,
            shareAmountValue: NSDecimalNumber(decimal: share.shareAmount).stringValue,
            shareCurrencyRaw: share.shareCurrency.rawValue,
            settled: share.settled,
            createdAt: share.createdAt,
            updatedAt: share.updatedAt
        )
    }

    func update(from share: SharedExpenseShare) {
        transactionID = share.transactionID
        paidBy = share.paidBy
        owedBy = share.owedBy
        shareAmountValue = NSDecimalNumber(decimal: share.shareAmount).stringValue
        shareCurrencyRaw = share.shareCurrency.rawValue
        settled = share.settled
        createdAt = share.createdAt
        updatedAt = share.updatedAt
    }

    /// Strikte Auflösung (#23): korrupte Beträge oder Teilnehmer werfen
    /// statt still 0/leer/gleich zu maskieren.
    func toDomain() throws -> SharedExpenseShare {
        guard let amount = Decimal(string: shareAmountValue) else {
            throw PersistenceDecodingError.invalidAmount(field: "sharedExpenseShareAmount", raw: shareAmountValue)
        }
        guard amount > 0 else {
            throw PersistenceDecodingError.invalidAmount(field: "sharedExpenseShareAmount", raw: shareAmountValue)
        }
        do {
            return try SharedExpenseShare(
                id: id,
                transactionID: transactionID,
                paidBy: paidBy,
                owedBy: owedBy,
                shareAmount: amount,
                shareCurrency: CurrencyCode(shareCurrencyRaw),
                settled: settled,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        } catch let validation as GroupExpenseValidationError {
            throw PersistenceDecodingError.invalidSharedExpenseShare(
                field: "sharedExpenseShare",
                raw: "\(paidBy)/\(owedBy):\(validation)"
            )
        }
    }
}
