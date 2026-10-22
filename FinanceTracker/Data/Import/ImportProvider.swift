import Foundation

struct ImportFile: Sendable, Hashable {
    let fileName: String?
    let data: Data

    init(fileName: String? = nil, data: Data) {
        self.fileName = fileName
        self.data = data
    }
}

struct ImportedTransaction: Sendable, Hashable {
    var externalID: String?
    var status: TransactionStatus
    var kind: TransactionKind
    var amount: Money
    var bookedAt: Date?
    var authorizedAt: Date?
    var rawDescription: String?
    var rawMerchantName: String?
    var merchantDisplayName: String?
    var paymentMethod: PaymentMethod?
    var cryptoAsset: String?
    var cryptoAmount: Decimal?
    var cashbackAmount: Decimal?
    var cashbackCurrency: CurrencyCode?
    var originalAmount: Decimal?
    var originalCurrency: CurrencyCode?
    /// Vom Provider aus eigener Branchenangabe abgeleiteter Kategorie-
    /// Vorschlag (bereits normalisiert). Greift nur, wenn keine Regel passt.
    var suggestedCategoryID: Category.ID?
    /// Kontostand nach dieser Buchung, sofern die Datei ihn ausweist.
    var balanceAfter: Decimal?
    /// Aus der Gegenseite erkannt: eigenes Konto (Umbuchung) oder Broker
    /// (Geldanlage). Greift nach Regeln, aber vor Branchenwörtern.
    var counterpartyClass: CounterpartyClass?
    /// Lesbarer Händlername für erkannte Überweisungen („Trade Republic").
    var counterpartyLabel: String?

    init(
        externalID: String? = nil,
        status: TransactionStatus = .booked,
        kind: TransactionKind = .unknown,
        amount: Money,
        bookedAt: Date? = nil,
        authorizedAt: Date? = nil,
        rawDescription: String? = nil,
        rawMerchantName: String? = nil,
        merchantDisplayName: String? = nil,
        paymentMethod: PaymentMethod? = nil,
        cryptoAsset: String? = nil,
        cryptoAmount: Decimal? = nil,
        cashbackAmount: Decimal? = nil,
        cashbackCurrency: CurrencyCode? = nil,
        originalAmount: Decimal? = nil,
        originalCurrency: CurrencyCode? = nil,
        suggestedCategoryID: Category.ID? = nil,
        balanceAfter: Decimal? = nil,
        counterpartyClass: CounterpartyClass? = nil,
        counterpartyLabel: String? = nil
    ) {
        self.externalID = externalID
        self.status = status
        self.kind = kind
        self.amount = amount
        self.bookedAt = bookedAt
        self.authorizedAt = authorizedAt
        self.rawDescription = rawDescription
        self.rawMerchantName = rawMerchantName
        self.merchantDisplayName = merchantDisplayName
        self.paymentMethod = paymentMethod
        self.cryptoAsset = cryptoAsset
        self.cryptoAmount = cryptoAmount
        self.cashbackAmount = cashbackAmount
        self.cashbackCurrency = cashbackCurrency
        self.originalAmount = originalAmount
        self.originalCurrency = originalCurrency
        self.suggestedCategoryID = suggestedCategoryID
        self.balanceAfter = balanceAfter
        self.counterpartyClass = counterpartyClass
        self.counterpartyLabel = counterpartyLabel
    }
}

enum ImportLimits {
    static let maxFileSizeBytes = 50 * 1_024 * 1_024
    static let maxZipEntries = 5_000
    static let maxSingleUncompressedBytes = 25 * 1_024 * 1_024
    static let maxTotalExpandedBytes = 100 * 1_024 * 1_024
}

struct ImportRowIssue: Sendable, Hashable {
    let rowIndex: Int
    let reason: String

    var displayMessage: String { String(localized: "Zeile \(rowIndex): \(reason)") }
}

struct ProviderParseResult: Sendable, Equatable {
    let totalRows: Int
    let transactions: [ImportedTransaction]
    let issues: [ImportRowIssue]

    static func empty(totalRows: Int = 0) -> ProviderParseResult {
        ProviderParseResult(totalRows: totalRows, transactions: [], issues: [])
    }
}

enum ImportError: Error, Equatable, Sendable {
    case unsupportedFormat(reason: String)
    case missingColumns(missing: [String])
    case parsingFailed(stage: String, reason: String)

    var userFacingMessage: String {
        switch self {
        case .unsupportedFormat(let reason):
            String(localized: "Das Dateiformat konnte nicht als Import erkannt werden. \(reason)")
        case .missingColumns(let missing):
            String(localized: "Es fehlen erforderliche Spalten: \(missing.joined(separator: ", ")).")
        case .parsingFailed(let stage, let reason):
            String(localized: "Der Import ist an Schritt „\(stage)“ gescheitert. \(reason)")
        }
    }

    /// Grund für einen noch nicht abgeschlossenen Bank-Login. Der
    /// ConnectionHealthEvaluator erkennt ihn daran (sprachunabhängig).
    static var connectionNotAuthorizedReason: String {
        String(localized: "Die Bankverbindung ist noch nicht vollständig autorisiert.")
    }
}

protocol ImportProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var transactionSource: TransactionSource { get }

    func canHandle(_ file: ImportFile) async throws -> Bool
    func parse(_ file: ImportFile) async throws -> ProviderParseResult
}
