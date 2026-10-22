import Foundation

enum TransactionSource: String, Codable, Sendable, CaseIterable {
    case demo
    case manual
    case genericCSV
    case etherFiCashCSV
    case metamaskCardCSV
    case openBanking
    case blockchain

    var displayName: String {
        switch self {
        case .demo: String(localized: "Demo-Daten")
        case .manual: String(localized: "Manuell erfasst")
        case .genericCSV, .etherFiCashCSV, .metamaskCardCSV: String(localized: "Datei-Import")
        case .openBanking: "Open Banking"
        case .blockchain: "Blockchain"
        }
    }
}

enum TransactionStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case booked
    case reversed
    case cancelled

    var displayName: String {
        switch self {
        case .pending: String(localized: "Ausstehend")
        case .booked: String(localized: "Gebucht")
        case .reversed: String(localized: "Rückgängig")
        case .cancelled: String(localized: "Storniert")
        }
    }
}

enum TransactionKind: String, Codable, Sendable, CaseIterable {
    case purchase
    case refund
    case transfer
    case fee
    case income
    case cashback
    case unknown

    var displayName: String {
        switch self {
        case .purchase: String(localized: "Kauf")
        case .refund: String(localized: "Erstattung")
        case .transfer: String(localized: "Umbuchung")
        case .fee: String(localized: "Gebühr")
        case .income: String(localized: "Einnahme")
        case .cashback: "Cashback"
        case .unknown: String(localized: "Unbekannt")
        }
    }
}

enum PaymentMethod: String, Codable, Sendable {
    case cardPresent
    case cardOnline
    case bankTransfer
    case directDebit
    case standingOrder
    case cash
    case crypto
    case other

    var displayName: String {
        switch self {
        case .cardPresent: String(localized: "Karte (physisch)")
        case .cardOnline: String(localized: "Karte (online)")
        case .bankTransfer: String(localized: "Überweisung")
        case .directDebit: String(localized: "Lastschrift")
        case .standingOrder: String(localized: "Dauerauftrag")
        case .cash: String(localized: "Bargeld")
        case .crypto: "Crypto"
        case .other: String(localized: "Sonstiges")
        }
    }
}

struct Transaction: Identifiable, Hashable, Codable, Sendable {
    let id: UUID

    var accountID: UUID
    var source: TransactionSource

    var externalID: String?
    var sourceFingerprint: String?

    var status: TransactionStatus
    var kind: TransactionKind

    var amount: Money

    var bookedAt: Date?
    var authorizedAt: Date?
    var valueDate: Date?

    var rawDescription: String?
    var rawMerchantName: String?

    var merchantID: UUID?
    var merchantDisplayName: String?

    var categoryID: UUID?

    var paymentMethod: PaymentMethod?

    var originalCurrency: CurrencyCode?
    var originalAmount: Decimal?

    var cryptoAsset: String?
    var cryptoAmount: Decimal?

    var cashbackAmount: Decimal?
    var cashbackCurrency: CurrencyCode?

    var note: String?
    var reviewed: Bool
    var excludedFromAnalytics: Bool
    var tagIDs: [UUID]?

    var importBatchID: UUID?

    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        accountID: UUID,
        source: TransactionSource,
        externalID: String? = nil,
        sourceFingerprint: String? = nil,
        status: TransactionStatus = .booked,
        kind: TransactionKind = .unknown,
        amount: Money,
        bookedAt: Date? = nil,
        authorizedAt: Date? = nil,
        valueDate: Date? = nil,
        rawDescription: String? = nil,
        rawMerchantName: String? = nil,
        merchantID: UUID? = nil,
        merchantDisplayName: String? = nil,
        categoryID: UUID? = nil,
        paymentMethod: PaymentMethod? = nil,
        originalCurrency: CurrencyCode? = nil,
        originalAmount: Decimal? = nil,
        cryptoAsset: String? = nil,
        cryptoAmount: Decimal? = nil,
        cashbackAmount: Decimal? = nil,
        cashbackCurrency: CurrencyCode? = nil,
        note: String? = nil,
        reviewed: Bool = false,
        excludedFromAnalytics: Bool = false,
        tagIDs: [UUID]? = nil,
        importBatchID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountID = accountID
        self.source = source
        self.externalID = externalID
        self.sourceFingerprint = sourceFingerprint
        self.status = status
        self.kind = kind
        self.amount = amount
        self.bookedAt = bookedAt
        self.authorizedAt = authorizedAt
        self.valueDate = valueDate
        self.rawDescription = rawDescription
        self.rawMerchantName = rawMerchantName
        self.merchantID = merchantID
        self.merchantDisplayName = merchantDisplayName
        self.categoryID = categoryID
        self.paymentMethod = paymentMethod
        self.originalCurrency = originalCurrency
        self.originalAmount = originalAmount
        self.cryptoAsset = cryptoAsset
        self.cryptoAmount = cryptoAmount
        self.cashbackAmount = cashbackAmount
        self.cashbackCurrency = cashbackCurrency
        self.note = note
        self.reviewed = reviewed
        self.excludedFromAnalytics = excludedFromAnalytics
        self.tagIDs = tagIDs
        self.importBatchID = importBatchID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var effectiveMerchantName: String {
        if let merchantDisplayName { return merchantDisplayName }
        if let rawMerchantName { return rawMerchantName }
        if let rawDescription { return rawDescription }
        return "Unbekannt"
    }

    var displayDate: Date {
        bookedAt ?? authorizedAt ?? valueDate ?? createdAt
    }

    /// Sortier-Schlüssel für die native Mac-Tabelle (nur Betragswert).
    /// Cross-Currency-Gruppierung übernimmt die Sortierlogik der Tabelle:
    /// bewusst KEIN FX-konvertierter Wert (Roadmap #32).
    var amountSortValue: Decimal {
        amount.amount
    }

    var isExpense: Bool { amount.isNegative }
}
