import Foundation

struct PendingBookedReconciler: Sendable {
    static let defaultDateTolerance: TimeInterval = 7 * 24 * 3600
    static let amountTolerance = Decimal(string: "0.01")!

    /// - Parameter includingCancelled: Auch Vormerkungen, die ein Bankabruf
    ///   storniert hat, weil die Bank sie nicht mehr meldete, kommen als Ziel
    ///   in Frage. Bucht die Bank den Umsatz doch noch, wird dieselbe Zeile
    ///   gebucht und Kategorie, Notiz und Belege bleiben. Vorgemerkte Zeilen
    ///   haben Vorrang vor stornierten.
    func findTarget(
        for incoming: Transaction,
        among candidates: [Transaction],
        includingCancelled: Bool = false
    ) -> Transaction? {
        guard incoming.status != .pending else { return nil }
        if let pending = match(incoming, among: candidates, status: .pending) { return pending }
        return includingCancelled ? match(incoming, among: candidates, status: .cancelled) : nil
    }

    private func match(
        _ incoming: Transaction,
        among candidates: [Transaction],
        status: TransactionStatus
    ) -> Transaction? {
        candidates.first { candidate in
            guard candidate.status == status else { return false }
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
