import Foundation

/// Überweisung zwischen zwei eigenen Konten, die beide in der App sind:
/// Ausgang und Eingang werden verknüpft und zählen nicht mehr als Ausgabe
/// bzw. Einnahme, sonst wären die Ausgaben doppelt (Überweisung + echte
/// Käufe auf dem anderen Konto).
///
/// Automatisch nur, wenn mindestens eine Seite an der Gegenseite als
/// eigenes Konto erkannt wurde (Kategorie „Umbuchungen") und keine Seite
/// eine andere Kategorie trägt. Andere Betragspaare bleiben Vorschläge in
/// der Prüfliste. Solange das Gegenkonto fehlt, zählt die Überweisung.
struct LinkOwnTransfers: Sendable {
    let transactionRepository: any TransactionRepository
    var detector = TransferDetector()

    @discardableResult
    func run(calendar: Calendar = .current) async throws -> Int {
        let all = try await transactionRepository.transactions(matching: TransactionQuery())
        let transfers = Category.transfers.id
        let open = all.filter { $0.kind != .transfer }
        // Zwei Durchgänge, damit eine gleich hohe fremde Buchung nicht das
        // Gegenstück wegschnappt: erst erkannte Ausgänge gegen offene
        // Eingänge, dann erkannte Eingänge gegen offene Ausgänge.
        let passes: [[Transaction]] = [
            open.filter { $0.amount.isNegative ? $0.categoryID == transfers : $0.categoryID == nil || $0.categoryID == transfers },
            open.filter { $0.amount.isNegative ? $0.categoryID == nil : $0.categoryID == transfers }
        ]
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var linkedIDs = Set<UUID>()
        var updates: [Transaction] = []

        for pass in passes {
            let remaining = pass.filter { !linkedIDs.contains($0.id) }
            for currency in Set(remaining.map(\.amount.currency)) {
                for candidate in detector.detect(transactions: remaining, baseCurrency: currency, calendar: calendar) {
                    guard let debit = byID[candidate.debitTransactionID],
                          let credit = byID[candidate.creditTransactionID],
                          !linkedIDs.contains(debit.id), !linkedIDs.contains(credit.id),
                          [debit.categoryID, credit.categoryID].contains(transfers) else { continue }
                    for side in [debit, credit] {
                        var updated = side
                        updated.kind = .transfer
                        updated.categoryID = transfers
                        updated.updatedAt = Date()
                        updates.append(updated)
                        linkedIDs.insert(side.id)
                    }
                }
            }
        }
        guard !updates.isEmpty else { return 0 }
        try await transactionRepository.upsert(updates)
        return updates.count / 2
    }
}

extension Transaction {
    /// Als Umbuchung erkannt, aber die Gegenbuchung ist (noch) nicht in der
    /// App: zählt deshalb weiter als Ausgabe bzw. Einnahme.
    var isUnlinkedOwnTransfer: Bool {
        categoryID == Category.transfers.id && kind != .transfer
    }
}
