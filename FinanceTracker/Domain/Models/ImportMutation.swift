import Foundation

struct TransactionSnapshot: Codable, Sendable, Hashable {
    var accountID: UUID
    var sourceRaw: String
    var externalID: String?
    var sourceFingerprint: String?
    var statusRaw: String
    var kindRaw: String?
    var amountValue: String
    var amountCurrencyRaw: String
    var bookedAt: Date?
    var authorizedAt: Date?
    var valueDate: Date?
    var rawDescription: String?
    var rawMerchantName: String?
    var merchantID: UUID?
    var merchantDisplayName: String?
    var categoryID: UUID?
    var paymentMethodRaw: String?
    var originalCurrencyRaw: String?
    var originalAmountValue: String?
    var cryptoAsset: String?
    var cryptoAmountValue: String?
    var cashbackAmountValue: String?
    var cashbackCurrencyRaw: String?
    var importBatchID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(transaction: Transaction) {
        self.accountID = transaction.accountID
        self.sourceRaw = transaction.source.rawValue
        self.externalID = transaction.externalID
        self.sourceFingerprint = transaction.sourceFingerprint
        self.statusRaw = transaction.status.rawValue
        self.kindRaw = transaction.kind.rawValue
        self.amountValue = transaction.amount.amount.description
        self.amountCurrencyRaw = transaction.amount.currency.rawValue
        self.bookedAt = transaction.bookedAt
        self.authorizedAt = transaction.authorizedAt
        self.valueDate = transaction.valueDate
        self.rawDescription = transaction.rawDescription
        self.rawMerchantName = transaction.rawMerchantName
        self.merchantID = transaction.merchantID
        self.merchantDisplayName = transaction.merchantDisplayName
        self.categoryID = transaction.categoryID
        self.paymentMethodRaw = transaction.paymentMethod?.rawValue
        self.originalCurrencyRaw = transaction.originalCurrency?.rawValue
        self.originalAmountValue = transaction.originalAmount.map(\.description)
        self.cryptoAsset = transaction.cryptoAsset
        self.cryptoAmountValue = transaction.cryptoAmount.map(\.description)
        self.cashbackAmountValue = transaction.cashbackAmount.map(\.description)
        self.cashbackCurrencyRaw = transaction.cashbackCurrency?.rawValue
        self.importBatchID = transaction.importBatchID
        self.createdAt = transaction.createdAt
        self.updatedAt = transaction.updatedAt
    }

    func restoring(id: UUID) -> Transaction {
        Transaction(
            id: id,
            accountID: accountID,
            source: TransactionSource(rawValue: sourceRaw) ?? .manual,
            externalID: externalID,
            sourceFingerprint: sourceFingerprint,
            status: TransactionStatus(rawValue: statusRaw) ?? .booked,
            kind: kindRaw.flatMap(TransactionKind.init(rawValue:)) ?? .unknown,
            amount: Money(
                amount: Decimal(string: amountValue) ?? 0,
                currency: CurrencyCode(amountCurrencyRaw)
            ),
            bookedAt: bookedAt,
            authorizedAt: authorizedAt,
            valueDate: valueDate,
            rawDescription: rawDescription,
            rawMerchantName: rawMerchantName,
            merchantID: merchantID,
            merchantDisplayName: merchantDisplayName,
            categoryID: categoryID,
            paymentMethod: paymentMethodRaw.flatMap(PaymentMethod.init(rawValue:)),
            originalCurrency: originalCurrencyRaw.map(CurrencyCode.init),
            originalAmount: originalAmountValue.flatMap { Decimal(string: $0) },
            cryptoAsset: cryptoAsset,
            cryptoAmount: cryptoAmountValue.flatMap { Decimal(string: $0) },
            cashbackAmount: cashbackAmountValue.flatMap { Decimal(string: $0) },
            cashbackCurrency: cashbackCurrencyRaw.map(CurrencyCode.init),
            importBatchID: importBatchID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct ImportMutation: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case inserted
        case updated
    }

    let transactionID: UUID
    let kind: Kind
    let previousSnapshot: TransactionSnapshot?

    init(transactionID: UUID, kind: Kind, previousSnapshot: TransactionSnapshot?) {
        self.transactionID = transactionID
        self.kind = kind
        self.previousSnapshot = previousSnapshot
    }
}
