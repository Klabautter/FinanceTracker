import Foundation

enum AccountType: String, Codable, Sendable, CaseIterable {
    case checking
    case savings
    case creditCard
    case prepaidCard
    case cryptoCard
    case cash
    case wallet
    case other

    var displayName: String {
        switch self {
        case .checking: String(localized: "Girokonto")
        case .savings: String(localized: "Sparbuch")
        case .creditCard: String(localized: "Kreditkarte")
        case .prepaidCard: String(localized: "Prepaid-Karte")
        case .cryptoCard: String(localized: "Crypto-Card")
        case .cash: String(localized: "Bargeld")
        case .wallet: "Wallet"
        case .other: String(localized: "Sonstiges")
        }
    }

    var systemImage: String {
        switch self {
        case .checking: "banknote"
        case .savings: "building.columns"
        case .creditCard, .prepaidCard, .wallet, .other: "creditcard"
        case .cryptoCard: "bitcoinsign.circle"
        case .cash: "banknote"
        }
    }
}

enum AccountSource: String, Codable, Sendable {
    case demo
    case manual
    case csvImport
    case openBanking
    case blockchain
}

struct Account: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var connectionID: UUID?
    var institutionID: String?
    var name: String
    var type: AccountType
    var currency: CurrencyCode
    var maskedIdentifier: String?
    var ibanLast4: String?
    var providerAccountID: String?
    var source: AccountSource
    var isActive: Bool
    /// Stand zu Beginn des Tages `openingBalanceDate` (Kontowährung). Nur
    /// gesetzt, wenn der Nutzer ihn erfasst hat, z. B. Bargeld im Geldbeutel.
    /// Kein Umsatz, zählt nie als Einnahme oder Ausgabe.
    var openingBalance: Decimal?
    var openingBalanceDate: Date?

    init(
        id: UUID = UUID(),
        connectionID: UUID? = nil,
        institutionID: String? = nil,
        name: String,
        type: AccountType,
        currency: CurrencyCode,
        maskedIdentifier: String? = nil,
        ibanLast4: String? = nil,
        providerAccountID: String? = nil,
        source: AccountSource,
        isActive: Bool = true,
        openingBalance: Decimal? = nil,
        openingBalanceDate: Date? = nil
    ) {
        self.id = id
        self.connectionID = connectionID
        self.institutionID = institutionID
        self.name = name
        self.type = type
        self.currency = currency
        self.maskedIdentifier = maskedIdentifier
        self.ibanLast4 = ibanLast4
        self.providerAccountID = providerAccountID
        self.source = source
        self.isActive = isActive
        self.openingBalance = openingBalance
        self.openingBalanceDate = openingBalanceDate
    }
}
