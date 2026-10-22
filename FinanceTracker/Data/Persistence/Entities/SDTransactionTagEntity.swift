import Foundation
import SwiftData

/// WP19: Normalisierte Tag-Relation (V8).
///
/// Querybar per SQL-Pushdown (Tag-Filter, Usage-Counts, Tag-Delete) statt
/// JSON-Dekodierung aller Annotationen. Source of Truth für die Tag-Zuordnung
/// bleibt `Transaction.tagIDs` (JSON auf der Transaktion/Annotation); die
/// Join-Rows werden beim Schreiben synchron gehalten (Write-through) und
/// für Bestände idempotent zurückgefüllt (Backfill on first use).
@Model
final class SDTransactionTagEntity {
    @Attribute(.unique) var id: UUID
    var transactionID: UUID
    var tagID: UUID

    init(id: UUID = UUID(), transactionID: UUID, tagID: UUID) {
        self.id = id
        self.transactionID = transactionID
        self.tagID = tagID
    }
}
