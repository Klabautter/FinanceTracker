import Foundation

/// Überweisung zwischen zwei eigenen Konten, die beide in der App sind:
/// Ausgang und Eingang werden verknüpft und zählen nicht mehr als Ausgabe
/// bzw. Einnahme, sonst wären die Ausgaben doppelt (Überweisung + echte
/// Käufe auf dem anderen Konto).
///
/// Automatisch, wenn mindestens eine Seite als Geld zwischen eigenen
/// Konten erkannt wurde („Umbuchungen" oder „Geldanlage", z. B. die
/// Einzahlung zum Broker) und die andere Seite keine fremde Kategorie
/// trägt (Nutzer-Entscheid 10.11.2026). Die Kategorie bleibt sichtbar:
/// Eine Broker-Einzahlung heißt weiter „Geldanlage", zählt aber als
/// Umbuchung. Andere Betragspaare bleiben Vorschläge in der Prüfliste.
/// Solange das Gegenkonto fehlt, zählt die Überweisung.
struct LinkOwnTransfers: Sendable {
    let transactionRepository: any TransactionRepository
    var detector = TransferDetector()

    /// Kategorien, die eine Seite als eigenes Geld ausweisen.
    static let ownMoneyCategoryIDs: Set<UUID> = [Category.transfers.id, Category.investments.id]

    @discardableResult
    func run(calendar: Calendar = .current) async throws -> Int {
        let all = try await transactionRepository.transactions(matching: TransactionQuery())
        let own = Self.ownMoneyCategoryIDs
        func isOwnMoney(_ txn: Transaction) -> Bool { txn.categoryID.map(own.contains) ?? false }
        func isOpenOrOwn(_ txn: Transaction) -> Bool { txn.categoryID == nil || isOwnMoney(txn) }
        let open = all.filter { $0.kind != .transfer }
        // Zwei Durchgänge, damit eine gleich hohe fremde Buchung nicht das
        // Gegenstück wegschnappt: erst erkannte Ausgänge gegen offene
        // Eingänge, dann erkannte Eingänge gegen offene Ausgänge.
        let passes: [[Transaction]] = [
            open.filter { $0.amount.isNegative ? isOwnMoney($0) : isOpenOrOwn($0) },
            open.filter { $0.amount.isNegative ? $0.categoryID == nil : isOwnMoney($0) }
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
                          isOwnMoney(debit) || isOwnMoney(credit) else { continue }
                    // Die erkannte Seite gibt der offenen ihre Kategorie.
                    let category = [debit, credit].compactMap(\.categoryID).first { own.contains($0) } ?? Category.transfers.id
                    for side in [debit, credit] {
                        var updated = side
                        updated.kind = .transfer
                        if updated.categoryID == nil { updated.categoryID = category }
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
