import Foundation

/// Bestätigte Fixkosten merken sich „dieser Händler auf diesem Konto". Wird
/// das Konto gelöscht (z. B. ein doppelt angelegtes nach einer Neu-
/// Verbindung), zeigt die Fixkost ins Leere: Ihre Zahlungen werden nicht mehr
/// erkannt und der Händler wird erneut vorgeschlagen.
///
/// Gibt es dieselben Händler-Buchungen auf genau einem vorhandenen Konto,
/// wird die Fixkost dorthin umgehängt. Sonst bleibt sie unverändert und gilt
/// als verwaist (`orphanedIDs`), nichts wird geraten oder still gelöscht.
struct RelinkOrphanedCommitments: Sendable {
    struct Outcome: Sendable, Equatable {
        var relinkedCount = 0
        var orphanedIDs: Set<RecurringCommitment.ID> = []
    }

    let commitmentRepository: any RecurringCommitmentRepository
    let accountRepository: any AccountRepository
    let transactionRepository: any TransactionRepository

    @discardableResult
    func run() async throws -> Outcome {
        let accountIDs = Set(try await accountRepository.accounts().map(\.id))
        let orphans = try await commitmentRepository.commitments().filter { commitment in
            guard let accountID = commitment.matchingAccountID else { return false }
            return !accountIDs.contains(accountID)
        }
        guard !orphans.isEmpty else { return Outcome() }

        let transactions = try await transactionRepository.transactions(matching: TransactionQuery())
        let normalizer = MerchantNormalizer()
        var outcome = Outcome()
        var updates: [RecurringCommitment] = []

        for commitment in orphans {
            guard let merchantKey = commitment.matchingMerchantKey else { continue }
            let candidateAccounts = Set(transactions.compactMap { transaction -> UUID? in
                guard accountIDs.contains(transaction.accountID),
                      transaction.amount.currency == commitment.currency,
                      Self.merchantKey(of: transaction, normalizer: normalizer) == merchantKey else { return nil }
                return transaction.accountID
            })
            guard candidateAccounts.count == 1, let accountID = candidateAccounts.first else {
                outcome.orphanedIDs.insert(commitment.id)
                continue
            }
            var relinked = commitment
            relinked.merchantKey = RecurringMerchantIdentity(accountID: accountID, merchantKey: merchantKey).persistedKey
            relinked.updatedAt = Date()
            updates.append(relinked)
        }

        if !updates.isEmpty {
            try await commitmentRepository.upsert(updates)
        }
        outcome.relinkedCount = updates.count
        return outcome
    }

    /// Dieselbe Händler-Kennung wie in `RecurringPaymentsDetector`.
    private static func merchantKey(of transaction: Transaction, normalizer: MerchantNormalizer) -> String {
        if let merchantID = transaction.merchantID { return merchantID.uuidString }
        let raw = transaction.merchantDisplayName ?? transaction.rawMerchantName ?? ""
        return CategoryRuleEngine.normalizedKey(normalizer.canonicalDisplayName(from: raw) ?? raw)
    }
}
