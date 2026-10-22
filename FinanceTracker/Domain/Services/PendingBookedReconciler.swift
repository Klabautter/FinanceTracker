import Foundation

struct PendingBookedReconciler: Sendable {
    static let defaultDateTolerance: TimeInterval = 7 * 24 * 3600
    static let amountTolerance = Decimal(string: "0.01")!

    func findTarget(
        for incoming: Transaction,
        among candidates: [Transaction]
    ) -> Transaction? {
        guard incoming.status != .pending else { return nil }

        return candidates.first { candidate in
            guard candidate.status == .pending else { return false }
            guard candidate.accountID == incoming.accountID else { return false }
            guard candidate.source == incoming.source else { return false }
            guard candidate.amount.currency == incoming.amount.currency else { return false }

            let candidateAbs = abs(candidate.amount.amount)
            let incomingAbs = abs(incoming.amount.amount)
            let difference = candidateAbs > incomingAbs ? candidateAbs - incomingAbs : incomingAbs - candidateAbs
            guard difference <= Self.amountTolerance else { return false }

            let candidateDate = candidate.displayDate
            let incomingDate = incoming.displayDate
            let distance = abs(candidateDate.timeIntervalSince(incomingDate))
            guard distance <= Self.defaultDateTolerance else { return false }

            return merchantsAreSimilar(candidate.effectiveMerchantName, incoming.effectiveMerchantName)
        }
    }

    private func merchantsAreSimilar(_ lhs: String, _ rhs: String) -> Bool {
        let left = CategoryRuleEngine.normalizedKey(lhs)
        let right = CategoryRuleEngine.normalizedKey(rhs)
        guard !left.isEmpty, !right.isEmpty else { return true }
        return left.contains(right) || right.contains(left)
    }
}
