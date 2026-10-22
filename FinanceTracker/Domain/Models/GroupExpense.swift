import Foundation

/// P2 Splitwise-light (klein halten, #11 kein Parallelmodell).
///
/// User-Metadaten (#27): Anteile an einer bezahlten Transaktion, die
/// Transaktion selbst bleibt Provider-Fakt, nur die Aufteilung ist
/// User-Besitz (wie `TransactionAnnotation`). Kein PIS (#15): Ausgleich
/// passiert ausschließlich als manuelle Transfer-Buchung (neutral, #28).
///
/// Persistenz: `SDSharedExpenseShareEntity` (V12-Sidecar, je Transaktion N
/// Zeilen). UI: `GroupExpenseSectionView` im Transaktionsdetail
/// („Aufteilen“). Ausgleichs-Semantik: `GroupExpenseResolver` je Währung
/// getrennt (#19/#35).
enum GroupExpenseValidationError: Error, Equatable, Sendable {
    case emptyParticipant
    case samePayerAndOwer
    case nonPositiveShare
}

struct SharedExpenseShare: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    /// Bezahlte Transaktion (Referenz, kein Besitz: Provider-Fakt).
    let transactionID: UUID
    /// Wer hat vorgestreckt (freies Nutzer-Label, z. B. „Alex“).
    var paidBy: String
    /// Wer schuldet diesen Anteil (freies Nutzer-Label).
    var owedBy: String
    /// Anteil (> 0) in `shareCurrency`.
    var shareAmount: Decimal
    var shareCurrency: CurrencyCode
    var settled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        transactionID: UUID,
        paidBy: String,
        owedBy: String,
        shareAmount: Decimal,
        shareCurrency: CurrencyCode,
        settled: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        let payer = paidBy.trimmingCharacters(in: .whitespacesAndNewlines)
        let ower = owedBy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payer.isEmpty, !ower.isEmpty else {
            throw GroupExpenseValidationError.emptyParticipant
        }
        guard payer != ower else {
            throw GroupExpenseValidationError.samePayerAndOwer
        }
        guard shareAmount > 0 else {
            throw GroupExpenseValidationError.nonPositiveShare
        }
        self.id = id
        self.transactionID = transactionID
        self.paidBy = payer
        self.owedBy = ower
        self.shareAmount = shareAmount
        self.shareCurrency = shareCurrency
        self.settled = settled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                transactionID: container.decode(UUID.self, forKey: .transactionID),
                paidBy: container.decode(String.self, forKey: .paidBy),
                owedBy: container.decode(String.self, forKey: .owedBy),
                shareAmount: container.decode(Decimal.self, forKey: .shareAmount),
                shareCurrency: container.decode(CurrencyCode.self, forKey: .shareCurrency),
                settled: container.decode(Bool.self, forKey: .settled),
                createdAt: container.decode(Date.self, forKey: .createdAt),
                updatedAt: container.decode(Date.self, forKey: .updatedAt)
            )
        } catch let error as GroupExpenseValidationError {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid shared expense share: \(error)"
            ))
        }
    }
}

/// Vorgeschlagener Ausgleich (immer einseitig pro Währung, #19/#35: keine
/// Cross-Currency-Verrechnung). Als `Transaction(kind: .transfer)` zu buchen
/// (neutral, #28, kein Einfluss auf Analytics/Budget/Forecast).
struct SettlementTransfer: Hashable, Sendable, Equatable {
    var from: String
    var to: String
    var amount: Decimal
    var currency: CurrencyCode
}
