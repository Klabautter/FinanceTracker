import Foundation
import SwiftData

/// WP38: Normalisierter Suchindex (V9), NICHT-optionaler gefoldeter Text
/// pro Transaktion. `#Predicate.contains` ist auf nicht-optionalen Strings
/// SQL-seitig generierbar (auf Optionals crasht es: siehe
/// loadTransactionPage-Kommentar), dadurch wird die Suche zu einem echten
/// Pushdown statt einem 50k-Light-Fetch mit In-Memory-Filter.
///
/// Source of Truth bleibt die Transaktion; die Zeile wird beim Upsert
/// synchron gehalten (Write-through) und für Bestände idempotent
/// zurückgefüllt (Backfill on first use).
@Model
final class SDTransactionSearchEntity {
    @Attribute(.unique) var transactionID: UUID
    var searchableText: String

    init(transactionID: UUID, searchableText: String) {
        self.transactionID = transactionID
        self.searchableText = searchableText
    }
}
