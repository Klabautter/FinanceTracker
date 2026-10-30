import Foundation

/// Was eine Buchungsart aus einem Export bedeutet, unabhängig von Bank und
/// Sprache. Bestimmt Art und Vorzeichen der importierten Buchung.
enum TransactionTypeMeaning: String, Codable, Sendable, CaseIterable, Identifiable {
    case expense
    case income
    case transfer
    case refund
    case cashback
    case fee

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .expense: String(localized: "Ausgabe")
        case .income: String(localized: "Einnahme")
        case .transfer: String(localized: "Umbuchung")
        case .refund: String(localized: "Erstattung")
        case .cashback: String(localized: "Cashback")
        case .fee: String(localized: "Gebühr")
        }
    }

    /// Passt das Vorzeichen einer vorzeichenbehafteten Datei zur Art? Eine
    /// Gutschrift mit „Kartenzahlung" ist keine Ausgabe: dann entscheidet
    /// das Vorzeichen, nicht das Wort.
    func agrees(withSignOf money: Money) -> Bool {
        switch self {
        case .expense, .fee: money.amount <= 0
        case .income, .refund, .cashback: money.amount >= 0
        case .transfer: true
        }
    }

    var kind: TransactionKind {
        switch self {
        case .expense: .purchase
        case .income: .income
        case .transfer: .transfer
        case .refund: .refund
        case .cashback: .cashback
        case .fee: .fee
        }
    }

    /// Für Dateien ohne Vorzeichen (alle Beträge positiv, die Richtung steht
    /// in der Art): Ausgaben und Gebühren gehen ab, Einnahmen, Erstattungen
    /// und Cashback kommen an. Bei Umbuchungen bleibt der Betrag, wie er ist.
    func signed(_ money: Money) -> Money {
        switch self {
        case .expense, .fee:
            Money(amount: -abs(money.amount), currency: money.currency)
        case .income, .refund, .cashback:
            Money(amount: abs(money.amount), currency: money.currency)
        case .transfer:
            money
        }
    }
}

/// Buchungsarten, wie Banken und Kartenanbieter sie auf Deutsch und Englisch
/// in ihre Exporte schreiben („Card purchase", „card_spend",
/// „Kartenzahlung", „Einzahlung", „Saveback"). Unbekanntes ergibt `nil`:
/// Die Import-Vorschau fragt dann nach, statt zu raten (#17).
///
/// Bewusst nicht enthalten sind mehrdeutige Arten: „Überweisung" und
/// „Transfer" sind auf dem Girokonto meist Zahlungen an andere, auf einer
/// Karte eher eigene Aufladungen; „Withdrawal" ist mal Bargeld, mal
/// Auszahlung auf ein eigenes Konto.
enum TransactionTypeVocabulary {
    /// Reihenfolge = Priorität: „Card cashback" ist Cashback, nicht Ausgabe;
    /// „Refund fee" ist eine Gebühr.
    private static let entries: [(meaning: TransactionTypeMeaning, phrases: [String])] = [
        (.fee, [
            "FEE", "FEES", "GEBUHR", "GEBUHREN", "GEBUEHR", "GEBUEHREN", "ENTGELT", "ENTGELTE",
            "KONTOFUHRUNG", "KONTOFUEHRUNG", "KONTOFUHRUNGSGEBUHR", "SERVICE CHARGE", "CHARGE FEE",
            "GAS FEE", "FX FEE", "ATM FEE", "ORDERGEBUHR", "DEPOTGEBUHR",
            "STEUER", "STEUERN", "KAPITALERTRAGSTEUER", "TAX", "TAXES", "WITHHOLDING TAX"
        ]),
        (.cashback, [
            "CASHBACK", "CASH BACK", "REWARD", "REWARDS", "CASH REWARD", "SAVEBACK",
            "EMPFEHLUNG", "EMPFEHLUNGSPRAMIE", "REFERRAL", "REFERRAL BONUS",
            "RUCKVERGUTUNG", "RUECKVERGUETUNG"
        ]),
        (.refund, [
            "REFUND", "CARD REFUND", "REIMBURSEMENT", "CHARGEBACK", "ERSTATTUNG", "RUCKERSTATTUNG",
            "RUECKERSTATTUNG", "GUTSCHRIFT RUCKGABE", "RUCKGABE", "RUECKGABE", "STORNO", "REVERSAL"
        ]),
        (.transfer, [
            "RECEIVE", "DEPOSIT", "TOP UP", "TOPUP", "TOP UPS", "LOAD", "CARD LOAD",
            "ADD MONEY", "MONEY ADDED", "FUNDING", "EINZAHLUNG", "AUFLADUNG", "KARTENAUFLADUNG",
            "UMBUCHUNG", "EIGENUBERTRAG", "EIGENUEBERTRAG", "INTERNAL TRANSFER", "OWN TRANSFER",
            "EXCHANGE", "CURRENCY EXCHANGE", "CONVERSION", "CONVERT", "SWAP", "WECHSEL", "WAHRUNGSWECHSEL",
            "WAEHRUNGSWECHSEL", "GELDWECHSEL"
        ]),
        (.income, [
            "INTEREST", "INTEREST PAYMENT", "ZINSEN", "ZINSZAHLUNG", "ZINSGUTSCHRIFT", "HABENZINSEN",
            "DIVIDEND", "DIVIDENDE", "CASH DIVIDEND", "ERTRAG", "ERTRAGE", "ERTRAEGE", "AUSSCHUTTUNG", "AUSSCHUETTUNG", "SALARY", "GEHALT",
            "LOHN", "INCOME", "EINKOMMEN", "EINNAHME"
        ]),
        (.income, [
            "SELL", "SELL TRADE", "VERKAUF", "WERTPAPIERVERKAUF"
        ]),
        (.expense, [
            "BUY", "BUY TRADE", "SAVINGS PLAN", "SAVINGS PLAN EXECUTION", "SPARPLAN", "SPARPLANAUSFUHRUNG",
            "SPARPLANAUSFUEHRUNG", "WERTPAPIERKAUF",
            "PURCHASE", "CARD PURCHASE", "CARD SPEND", "CARD PAYMENT", "CARD TRANSACTION", "SPEND",
            "PAYMENT", "POS", "POS PAYMENT", "KARTENZAHLUNG", "KARTENUMSATZ", "KARTENTRANSAKTION",
            "KARTENEINSATZ", "KAUF", "EINKAUF", "ZAHLUNG", "LASTSCHRIFT", "SEPA LASTSCHRIFT",
            "ABBUCHUNG", "AUSGABE", "BELASTUNG", "DEBIT CARD", "DEBITKARTE", "KREDITKARTE"
        ])
    ]

    static func meaning(of rawType: String?) -> TransactionTypeMeaning? {
        guard let key = normalizedKey(rawType) else { return nil }
        // Ganze Bezeichnung zuerst, dann als Wortfolge darin („Card cashback").
        for entry in entries where entry.phrases.contains(key) {
            return entry.meaning
        }
        for entry in entries where entry.phrases.contains(where: { CategoryRuleEngine.containsTokenSequence(key, $0) }) {
            return entry.meaning
        }
        return nil
    }

    /// Schlüssel, unter dem die Vorschau Entscheidungen zu unbekannten Arten
    /// speichert („card_top-up" und „Card Top Up" sind dieselbe Art).
    static func normalizedKey(_ rawType: String?) -> String? {
        guard let rawType else { return nil }
        let key = CategoryRuleEngine.normalizedKey(rawType)
        return key.isEmpty ? nil : key
    }
}
