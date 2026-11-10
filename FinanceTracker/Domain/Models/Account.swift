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
    /// Zuletzt von Bank oder Datei gemeldeter Stand. Wird nicht über
    /// `upsert` geschrieben, sondern nur beim Abruf oder Import.
    var reportedBalance: ReportedBalance?
    /// „Nicht zum Gesamtstand zählen": Stand und Buchungen bleiben, nur
    /// Gesamtstand und Reichweite lassen das Konto aus (z. B. ein Depot-
    /// Verrechnungskonto oder Geld, das nicht dem Nutzer gehört).
    var excludedFromTotal: Bool
    /// „In der Kontenliste ausblenden", z. B. ein nicht mehr genutzter
    /// Währungstopf. Nur die Liste; Stand, Gesamtstand und Buchungen bleiben.
    var isHiddenInList: Bool

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
        openingBalanceDate: Date? = nil,
        reportedBalance: ReportedBalance? = nil,
        excludedFromTotal: Bool = false,
        isHiddenInList: Bool = false
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
        self.reportedBalance = reportedBalance
        self.excludedFromTotal = excludedFromTotal
        self.isHiddenInList = isHiddenInList
    }

    private enum CodingKeys: String, CodingKey {
        case id, connectionID, institutionID, name, type, currency, maskedIdentifier, ibanLast4
        case providerAccountID, source, isActive, openingBalance, openingBalanceDate, reportedBalance
        case excludedFromTotal, isHiddenInList
    }

    /// Ältere Backups kennen die Einstellung nicht: dann zählt das Konto mit.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        connectionID = try container.decodeIfPresent(UUID.self, forKey: .connectionID)
        institutionID = try container.decodeIfPresent(String.self, forKey: .institutionID)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(AccountType.self, forKey: .type)
        currency = try container.decode(CurrencyCode.self, forKey: .currency)
        maskedIdentifier = try container.decodeIfPresent(String.self, forKey: .maskedIdentifier)
        ibanLast4 = try container.decodeIfPresent(String.self, forKey: .ibanLast4)
        providerAccountID = try container.decodeIfPresent(String.self, forKey: .providerAccountID)
        source = try container.decode(AccountSource.self, forKey: .source)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        openingBalance = try container.decodeIfPresent(Decimal.self, forKey: .openingBalance)
        openingBalanceDate = try container.decodeIfPresent(Date.self, forKey: .openingBalanceDate)
        reportedBalance = try container.decodeIfPresent(ReportedBalance.self, forKey: .reportedBalance)
        excludedFromTotal = try container.decodeIfPresent(Bool.self, forKey: .excludedFromTotal) ?? false
        isHiddenInList = try container.decodeIfPresent(Bool.self, forKey: .isHiddenInList) ?? false
    }
}

/// Kontostand, wie die Bank oder ein Kontoauszug ihn zu einem Zeitpunkt
/// gemeldet hat. Buchungen nach `asOf` verändern ihn noch.
struct ReportedBalance: Hashable, Codable, Sendable {
    enum Source: String, Codable, Sendable {
        case bank
        case file
    }

    let amount: Money
    let asOf: Date
    let source: Source
}
