import Foundation

/// Händlervorschläge beim manuellen Anlegen eines Zahlungsplans: Buchungen
/// der letzten Monate mit gleicher Richtung und ähnlichem Betrag. Mit einem
/// gewählten Händler ordnet die App spätere Zahlungen sicher zu.
enum ManualCommitmentMerchantSuggestions {
    struct Suggestion: Identifiable, Hashable, Sendable {
        /// Gespeicherter Schlüssel (`RecurringMerchantIdentity.persistedKey`).
        let merchantKey: String
        let label: String
        let count: Int
        var id: String { merchantKey }
    }

    static func suggest(
        direction: RecurringCommitment.Direction,
        amount: Decimal?,
        currency: CurrencyCode,
        transactions: [Transaction],
        now: Date = Date(),
        calendar: Calendar = .current,
        limit: Int = 5
    ) -> [Suggestion] {
        guard let start = calendar.date(byAdding: .day, value: -120, to: now) else { return [] }
        let tolerance = amount.map { max(Decimal(1), $0 * Decimal(string: "0.10")!) }
        var groups: [String: (label: String, count: Int, latest: Date)] = [:]
        for txn in transactions {
            guard txn.status.isEffective, txn.amount.currency == currency else { continue }
            let date = txn.displayDate
            guard date >= start, date <= now else { continue }
            guard direction == .income ? txn.amount.amount > 0 : txn.amount.amount < 0 else { continue }
            if let amount, let tolerance, abs(abs(txn.amount.amount) - amount) > tolerance { continue }
            let name = txn.effectiveMerchantName
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let normalized = CategoryRuleEngine.normalizedKey(name)
            guard !normalized.isEmpty else { continue }
            let key = RecurringMerchantIdentity(accountID: txn.accountID, merchantKey: normalized).persistedKey
            let known = groups[key]
            groups[key] = (known?.label ?? name, (known?.count ?? 0) + 1, max(known?.latest ?? date, date))
        }
        return groups
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.value.latest > $1.value.latest }
            .prefix(limit)
            .map { Suggestion(merchantKey: $0.key, label: $0.value.label, count: $0.value.count) }
    }
}
