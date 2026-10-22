import Foundation

/// Splitwise-light Resolver (Scaffold, #27/#28, kein PIS #15).
///
/// - Eingabe: offene (`settled == false`) `SharedExpenseShare`s.
/// - Salden je Währung getrennt (#19/#35: niemals addieren/konvertieren).
///   Positiv = Guthaben (wird zurückbekommen), negativ = Schuld.
/// - Ausgleich: greedy Debitor→Kreditor pro Währung (deterministisch:
///   alphabetisch, dann Betrag). Ergebnis als `SettlementTransfer`s, die der
///   Nutzer als manuelle Transfer-Buchungen (`kind: .transfer`, neutral)
///   ausgleicht.
struct GroupExpenseResolver: Sendable {
    /// Netto-Salden pro Währung (nur offene Anteile).
    func netBalances(shares: [SharedExpenseShare]) -> [CurrencyCode: [String: Decimal]] {
        var balances: [CurrencyCode: [String: Decimal]] = [:]
        for share in shares where !share.settled {
            balances[share.shareCurrency, default: [:]][share.paidBy, default: 0] += share.shareAmount
            balances[share.shareCurrency, default: [:]][share.owedBy, default: 0] -= share.shareAmount
        }
        return balances
    }

    /// Ausgleichs-Transfers pro Währung (greedy, deterministisch).
    func settlementTransfers(shares: [SharedExpenseShare]) -> [SettlementTransfer] {
        let balances = netBalances(shares: shares)
        var transfers: [SettlementTransfer] = []
        for currency in balances.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let ledger = balances[currency] ?? [:]
            var creditors = ledger.filter { $0.value > 0 }.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            var debtors = ledger.filter { $0.value < 0 }.sorted {
                if $0.value != $1.value { return $0.value < $1.value }
                return $0.key < $1.key
            }
            var creditorIndex = 0
            var debtorIndex = 0
            while creditorIndex < creditors.count, debtorIndex < debtors.count {
                let creditor = creditors[creditorIndex]
                let debtor = debtors[debtorIndex]
                let amount = min(creditor.value, -debtor.value)
                guard amount > 0 else { break }
                transfers.append(SettlementTransfer(
                    from: debtor.key,
                    to: creditor.key,
                    amount: amount,
                    currency: currency
                ))
                let creditorLeft = creditor.value - amount
                let debtorLeft = debtor.value + amount
                creditors[creditorIndex].value = creditorLeft
                debtors[debtorIndex].value = debtorLeft
                if creditorLeft <= 0 { creditorIndex += 1 }
                if debtorLeft >= 0 { debtorIndex += 1 }
            }
        }
        return transfers
    }

    /// Fabrik für die Ausgleichs-Buchung: immer `kind: .transfer`
    /// (neutral, kein Einfluss auf Analytics/Budget/Forecast, #28).
    /// Betrag positiv auf dem Konto des Empfängers verbucht; die Gegenbuchung
    /// legt der Nutzer manuell auf dem Absender-Konto an (kein PIS, #15).
    func settlementTransaction(
        for transfer: SettlementTransfer,
        accountID: UUID,
        date: Date = Date()
    ) -> Transaction {
        Transaction(
            accountID: accountID,
            source: .manual,
            status: .booked,
            kind: .transfer,
            amount: Money(amount: transfer.amount, currency: transfer.currency),
            bookedAt: date,
            rawDescription: "Ausgleich \(transfer.from) → \(transfer.to)",
            rawMerchantName: "Ausgleich",
            merchantDisplayName: "Ausgleich \(transfer.from) → \(transfer.to)"
        )
    }
}
