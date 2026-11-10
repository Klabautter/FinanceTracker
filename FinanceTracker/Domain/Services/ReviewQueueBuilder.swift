import Foundation

struct ReviewItem: Identifiable, Hashable, Sendable {
    enum Reason: String, Sendable, Hashable, CaseIterable {
        case uncategorized = "Ohne Kategorie"
        case unknownMerchant = "Händler unbekannt"
        case possibleTransfer = "Möglicher Transfer"
        case foreignCurrency = "Fremdwährung"
    }

    let transaction: Transaction
    let reason: Reason
    var linkedTransactionID: UUID?

    var id: String { "\(reason.rawValue)|\(transaction.id.uuidString)" }

    init(transaction: Transaction, reason: Reason, linkedTransactionID: UUID? = nil) {
        self.transaction = transaction
        self.reason = reason
        self.linkedTransactionID = linkedTransactionID
    }
}

/// WP13 (§97): Globale Review-Kennzahl, das Dashboard zeigt „N Transaktionen
/// prüfen" als GESAMT offene Anzahl (nicht nur einen Zeitraum-Ausschnitt).
/// Alle Counts stammen aus derselben buildItems-Semantik wie die Queue
/// (§209: eine Implementierung, keine divergierenden Zähllogiken).
struct ReviewSummary: Sendable, Equatable {
    let uncategorizedCount: Int
    let unknownMerchantCount: Int
    let transferCandidateCount: Int
    let foreignCurrencyCount: Int

    var totalCount: Int {
        uncategorizedCount + unknownMerchantCount + transferCandidateCount + foreignCurrencyCount
    }
}

struct ReviewQueueBuilder: Sendable {
    private let transferDetector = TransferDetector()

    /// „Fremdwährung" ist ein Prüffall, wenn die Buchung nicht zur Währung
    /// ihres Kontos passt oder kein Kurs in die Basiswährung vorliegt. Eine
    /// Dollar-Buchung auf dem Dollar-Konto ist normal: sie zählt zum
    /// Tageskurs mit (Nutzer-Entscheid 10.11.2026). Ohne Kontowährung gilt
    /// die Basiswährung als Maßstab.
    static func isUnusualCurrency(
        _ transaction: Transaction,
        baseCurrency: CurrencyCode,
        accountCurrencies: [UUID: CurrencyCode],
        converter: CurrencyConverter?
    ) -> Bool {
        let accountCurrency = accountCurrencies[transaction.accountID] ?? baseCurrency
        if transaction.amount.currency != accountCurrency { return true }
        if transaction.amount.currency != baseCurrency, let converter,
           converter.rate(for: transaction, to: baseCurrency) == nil {
            return true
        }
        return false
    }

    func buildItems(
        transactions: [Transaction],
        baseCurrency: CurrencyCode,
        accountCurrencies: [UUID: CurrencyCode] = [:],
        converter: CurrencyConverter? = nil,
        calendar: Calendar = .current
    ) -> [ReviewItem] {
        let policy = CashflowPolicy.shared
        var items: [ReviewItem] = []

        for txn in transactions where txn.status.isEffective {
            guard !txn.reviewed else { continue }

            if policy.countsTowardBreakdowns(txn), txn.categoryID == nil {
                items.append(ReviewItem(transaction: txn, reason: .uncategorized))
            }

            if txn.effectiveMerchantName == "Unbekannt" || (txn.merchantID == nil && txn.rawMerchantName == nil) {
                items.append(ReviewItem(transaction: txn, reason: .unknownMerchant))
            }

            if Self.isUnusualCurrency(txn, baseCurrency: baseCurrency, accountCurrencies: accountCurrencies, converter: converter) {
                items.append(ReviewItem(transaction: txn, reason: .foreignCurrency))
            }
        }

        let candidates = transferDetector.detect(
            transactions: transactions,
            baseCurrency: baseCurrency,
            calendar: calendar
        )

        let byID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        for candidate in candidates {
            if let debit = byID[candidate.debitTransactionID], !debit.reviewed {
                items.append(ReviewItem(transaction: debit, reason: .possibleTransfer, linkedTransactionID: candidate.creditTransactionID))
            }
            if let credit = byID[candidate.creditTransactionID], !credit.reviewed {
                items.append(ReviewItem(transaction: credit, reason: .possibleTransfer, linkedTransactionID: candidate.debitTransactionID))
            }
        }

        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
            .sorted { $0.transaction.displayDate > $1.transaction.displayDate }
    }

    /// WP13 (§97): Globale Counts ohne ReviewItem-Allokation und Sortierung.
    /// Die Bedingungen bleiben deckungsgleich mit `buildItems`; Transferpaare
    /// sind durch den Detector eins-zu-eins und daher bereits eindeutig.
    func buildSummary(
        transactions: [Transaction],
        baseCurrency: CurrencyCode,
        accountCurrencies: [UUID: CurrencyCode] = [:],
        converter: CurrencyConverter? = nil,
        calendar: Calendar = .current
    ) -> ReviewSummary {
        let policy = CashflowPolicy.shared
        var uncategorizedCount = 0
        var unknownMerchantCount = 0
        var foreignCurrencyCount = 0

        for transaction in transactions where
            transaction.status.isEffective
                && !transaction.reviewed {
            if policy.countsTowardBreakdowns(transaction), transaction.categoryID == nil {
                uncategorizedCount += 1
            }
            if transaction.effectiveMerchantName == "Unbekannt"
                || (transaction.merchantID == nil && transaction.rawMerchantName == nil) {
                unknownMerchantCount += 1
            }
            if Self.isUnusualCurrency(transaction, baseCurrency: baseCurrency, accountCurrencies: accountCurrencies, converter: converter) {
                foreignCurrencyCount += 1
            }
        }

        let byID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        let transferCandidateCount = transferDetector.detect(
            transactions: transactions,
            baseCurrency: baseCurrency,
            calendar: calendar
        ).reduce(into: 0) { count, candidate in
            if byID[candidate.debitTransactionID]?.reviewed == false { count += 1 }
            if byID[candidate.creditTransactionID]?.reviewed == false { count += 1 }
        }

        return ReviewSummary(
            uncategorizedCount: uncategorizedCount,
            unknownMerchantCount: unknownMerchantCount,
            transferCandidateCount: transferCandidateCount,
            foreignCurrencyCount: foreignCurrencyCount
        )
    }
}
