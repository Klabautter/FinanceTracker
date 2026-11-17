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
        // Läuft bei jedem Start: Über die leichte Projection nur die Gruppen
        // finden, in denen etwas zu tun ist (alte ID oder mehrere Zeilen),
        // und nur deren Buchungen vollständig laden. Bei 100.000 Buchungen
        // hielte ein Voll-Load sonst rund 500 MB.
        let lightGroups = Self.groups(of: try await transactionRepository.reviewCandidateTransactions(), accountIDs: accountIDs)
        let candidateIDs = lightGroups.values
            .filter { rows in rows.count > 1 || rows.contains { $0.externalID.flatMap(Self.stableID(for:)) != nil } }
            .flatMap { $0.map(\.id) }
        guard !candidateIDs.isEmpty else { return Outcome() }
        var transactions: [Transaction] = []
        for start in stride(from: 0, to: candidateIDs.count, by: 1_000) {
            transactions += try await transactionRepository.transactions(
                ids: Set(candidateIDs[start..<min(start + 1_000, candidateIDs.count)])
            )
        }
        let groups = Self.groups(of: transactions, accountIDs: accountIDs)

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

    /// Gruppen je Konto + Währung + stabiler ID (nur Enable-Banking-Zeilen).
    private static func groups(of transactions: [Transaction], accountIDs: Set<UUID>?) -> [String: [Transaction]] {
        var groups: [String: [Transaction]] = [:]
        for transaction in transactions where transaction.source == .openBanking {
            if let accountIDs, !accountIDs.contains(transaction.accountID) { continue }
            guard let externalID = transaction.externalID, externalID.hasPrefix("eb-") else { continue }
            let stable = Self.stableID(for: externalID) ?? externalID
            let key = "\(transaction.accountID.uuidString)|\(transaction.amount.currency.rawValue)|\(stable)"
            groups[key, default: []].append(transaction)
        }
        return groups
    }

    private static func isSameBooking(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
        lhs.amount == rhs.amount
            && lhs.status == rhs.status
            && Calendar(identifier: .gregorian).isDate(lhs.displayDate, inSameDayAs: rhs.displayDate)
    }
}
