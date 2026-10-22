import Foundation

/// Enable-Banking-Buchungen trugen früher die Konto-`uid` in ihrer ID
/// („eb-<uid>-<entry_reference>"). Die `uid` gilt aber nur für eine Sitzung:
/// Nach jeder Neu-Autorisierung bekamen dieselben Buchungen neue IDs. Solange
/// der Händlername gleich blieb, fing der Fingerabdruck das ab: änderte er
/// sich (Absender statt Kontoinhaber bei Gutschriften), entstanden Doppelte.
///
/// Diese Migration stellt gespeicherte IDs auf „eb-<entry_reference>" um
/// (das Konto steckt ohnehin im Dedup-Schlüssel) und führt Doppelte zusammen:
/// Die älteste Zeile bleibt (Kategorie, Notiz, Tags des Nutzers), die
/// Provider-Fakten kommen von der neuesten. Idempotent.
struct EnableBankingExternalIDMigration: Sendable {
    let transactionRepository: any TransactionRepository

    private static let sessionScoped = try! NSRegularExpression(
        pattern: #"^eb-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}-(.+)$"#
    )

    static func stableID(for externalID: String) -> String? {
        let range = NSRange(externalID.startIndex..., in: externalID)
        guard let match = sessionScoped.firstMatch(in: externalID, range: range),
              let reference = Range(match.range(at: 1), in: externalID) else { return nil }
        return "eb-" + externalID[reference]
    }

    struct Outcome: Sendable, Equatable {
        var renamed = 0
        var merged = 0
    }

    @discardableResult
    func run(accountIDs: Set<UUID>? = nil) async throws -> Outcome {
        var query = TransactionQuery()
        query.sources = [.openBanking]
        if let accountIDs { query.accountIDs = accountIDs }
        let transactions = try await transactionRepository.transactions(matching: query)
            .filter { $0.externalID?.hasPrefix("eb-") == true }

        // Gruppen je Konto + Währung + stabiler ID.
        var groups: [String: [Transaction]] = [:]
        for transaction in transactions {
            guard let externalID = transaction.externalID else { continue }
            let stable = Self.stableID(for: externalID) ?? externalID
            let key = "\(transaction.accountID.uuidString)|\(transaction.amount.currency.rawValue)|\(stable)"
            groups[key, default: []].append(transaction)
        }

        var updates: [Transaction] = []
        var deletions = Set<UUID>()
        var outcome = Outcome()
        for (key, rows) in groups {
            let stable = String(key.split(separator: "|", maxSplits: 2)[2])
            let ordered = rows.sorted { $0.createdAt < $1.createdAt }
            guard var kept = ordered.first, let newest = ordered.last else { continue }
            // Nur echte Doppelte zusammenführen: gleicher Betrag, gleicher Tag.
            let duplicates = ordered.dropFirst().filter { Self.isSameBooking($0, kept) }
            var changed = kept.externalID != stable
            if changed { outcome.renamed += 1 }
            kept.externalID = stable
            if !duplicates.isEmpty, Self.isSameBooking(newest, kept) {
                kept.rawMerchantName = newest.rawMerchantName
                kept.merchantID = newest.merchantID
                kept.merchantDisplayName = newest.merchantDisplayName
                kept.rawDescription = newest.rawDescription ?? kept.rawDescription
                kept.sourceFingerprint = newest.sourceFingerprint
                if kept.categoryID == nil {
                    kept.categoryID = newest.categoryID
                    kept.kind = newest.kind
                }
                changed = true
            }
            for duplicate in duplicates {
                deletions.insert(duplicate.id)
                outcome.merged += 1
            }
            // Nicht zusammenführbare Zeilen mit derselben ID behalten ihre
            // alte ID, lieber sichtbar doppelt als falsch verschmolzen.
            if changed {
                kept.updatedAt = Date()
                updates.append(kept)
            }
        }

        if !deletions.isEmpty {
            try await transactionRepository.deleteTransactions(ids: deletions)
        }
        if !updates.isEmpty {
            try await transactionRepository.upsert(updates)
        }
        return outcome
    }

    private static func isSameBooking(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
        lhs.amount == rhs.amount
            && lhs.status == rhs.status
            && Calendar(identifier: .gregorian).isDate(lhs.displayDate, inSameDayAs: rhs.displayDate)
    }
}
