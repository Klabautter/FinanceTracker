import Foundation

/// Die andere Seite einer Überweisung, wie die Bank sie meldet.
struct Counterparty: Sendable, Hashable {
    var name: String?
    var iban: String?
    var bic: String?

    /// Fehlen IBAN oder BIC in den strukturierten Feldern, stehen sie bei
    /// vielen Banken im Verwendungszweck („… IBAN: DE… BIC: TRBKDEBBXXX").
    func completed(from description: String?) -> Counterparty {
        guard let description, iban == nil || bic == nil else { return self }
        var result = self
        if result.iban == nil {
            result.iban = Self.firstCapture(#"IBAN:\s*([A-Z]{2}[0-9]{2}[A-Z0-9]{10,30})"#, in: description)
        }
        if result.bic == nil {
            result.bic = Self.firstCapture(#"BIC:\s*([A-Z]{6}[A-Z0-9]{2}(?:[A-Z0-9]{3})?)\b"#, in: description)
        }
        return result
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Was eine Überweisung ist, wenn man nur auf die Gegenseite schaut.
enum CounterpartyClass: Sendable, Hashable {
    /// Gleicher Inhaber: Geld zwischen eigenen Konten. Zählt als Ausgabe
    /// bzw. Einnahme, bis die Gegenbuchung in der App ist; dann neutral.
    case ownAccount
    /// Depotbank oder Broker: zählt als Geldanlage.
    case broker

    var categoryID: Category.ID {
        switch self {
        case .ownAccount: Category.transfers.id
        case .broker: Category.investments.id
        }
    }
}

/// Erkennt Umbuchungen auf eigene Konten und Einzahlungen beim Broker an der
/// Gegenseite, unabhängig davon, ob das andere Konto in der App ist.
///
/// Broker gehen vor: Eine Einzahlung aufs eigene Depot ist Geldanlage, auch
/// wenn das Depot auf den eigenen Namen läuft.
enum CounterpartyClassifier {
    /// Bankleitzahl-Teil der BIC (die ersten acht Zeichen) von Depotbanken.
    static let brokerBICPrefixes: Set<String> = [
        "TRBKDEBB", // Trade Republic Bank
        "SCFBDE33", // Scalable Capital Bank
        "BDWBDEMM", // Baader Bank
        "FLFBDEMM"  // flatex Bank
    ]

    /// Bekannte Institute nach BIC-Anfang (8 Zeichen), für einen lesbaren
    /// Händlernamen statt des eigenen Namens.
    static let institutionNamesByBIC: [String: String] = [
        "TRBKDEBB": "Trade Republic",
        "SCFBDE33": "Scalable Capital",
        "BDWBDEMM": "Baader Bank",
        "FLFBDEMM": "flatex",
        "REVODEB2": "Revolut",
        "REVOLT21": "Revolut",
        "NTSBDEB1": "N26",
        "BYLADEM1": "DKB",
        "INGDDEFF": "ING",
        "COBADEFF": "Commerzbank",
        "DEUTDEFF": "Deutsche Bank",
        "COLSDE33": "Sparkasse KölnBonn",
        "GENODEF1": "Volksbank",
        "GENODEM1": "Volks- und Raiffeisenbank",
        "TRWIBEB1": "Wise",
        "PBNKDEFF": "Postbank",
        "HYVEDEMM": "HypoVereinsbank",
        "C24BDEB2": "C24 Bank",
        "SOBKDEB2": "Solarisbank",
        "QNTODEB2": "Qonto",
        "BUNQNL2A": "bunq",
        "INGBNL2A": "ING",
        "ABNANL2A": "ABN AMRO",
        "RABONL2U": "Rabobank",
        "BNPAFRPP": "BNP Paribas",
        "BOUSFRPP": "Boursorama",
        "SOGEFRPP": "Société Générale",
        "CAIXESBB": "CaixaBank",
        "BSCHESMM": "Santander",
        "BBVAESMM": "BBVA",
        "UNCRITMM": "UniCredit",
        "BARCGB22": "Barclays",
        "MIDLGB22": "HSBC",
        "NWBKGB2L": "NatWest",
        "MONZGB2L": "Monzo"
    ]

    static func institutionName(forBIC bic: String?) -> String? {
        guard let bic = bic?.uppercased(), bic.count >= 8 else { return nil }
        return institutionNamesByBIC[String(bic.prefix(8))]
    }

    /// Lesbarer Händlername für eine erkannte Überweisung: „Trade Republic"
    /// statt des eigenen Namens, „Revolut (eigenes Konto)".
    static func displayName(
        for kind: CounterpartyClass,
        counterparty: Counterparty,
        rawDescription: String?
    ) -> String {
        let details = counterparty.completed(from: rawDescription)
        let institution = institutionName(forBIC: details.bic)
        switch kind {
        case .broker:
            if let institution { return institution }
            let name = CategoryRuleEngine.normalizedKey(details.name ?? "")
            if brokerNames.contains(where: { CategoryRuleEngine.containsTokenSequence(name, $0) }) {
                return details.name ?? "Geldanlage"
            }
            return "Geldanlage"
        case .ownAccount:
            return institution.map { "\($0) (eigenes Konto)" } ?? "Eigenes Konto"
        }
    }

    static let brokerNames = [
        "TRADE REPUBLIC", "SCALABLE CAPITAL", "BAADER BANK", "FLATEX",
        "SMARTBROKER", "JUSTTRADE", "FINANZEN NET ZERO", "DEGIRO", "TRADING 212", "TRADING212",
        "INTERACTIVE BROKERS", "ETORO", "BITPANDA", "COINBASE", "KRAKEN", "BINANCE", "BISON APP"
    ]

    static func classify(
        _ counterparty: Counterparty,
        rawDescription: String?,
        ownerNames: [String]
    ) -> CounterpartyClass? {
        let details = counterparty.completed(from: rawDescription)
        if isBroker(details) { return .broker }
        if let name = details.name, ownerNames.contains(where: { isSamePerson(name, $0) }) {
            return .ownAccount
        }
        return nil
    }

    static func isBroker(_ counterparty: Counterparty) -> Bool {
        if let bic = counterparty.bic?.uppercased(), bic.count >= 8,
           brokerBICPrefixes.contains(String(bic.prefix(8))) {
            return true
        }
        let name = CategoryRuleEngine.normalizedKey(counterparty.name ?? "")
        return brokerNames.contains { CategoryRuleEngine.containsTokenSequence(name, $0) }
    }

    /// „Max Mustermann" und „Mustermann, Max" sind der Inhaber „Max
    /// Alexander Mustermann": „Erika Mustermann" nicht. Jedes Namensteil
    /// der Gegenseite muss im Inhabernamen vorkommen, mindestens zwei davon.
    static func isSamePerson(_ name: String, _ ownerName: String) -> Bool {
        let candidate = nameTokens(name)
        let owner = nameTokens(ownerName)
        guard candidate.count >= 2, !owner.isEmpty else { return false }
        return candidate.isSubset(of: owner)
    }

    private static let honorifics: Set<String> = ["HERR", "HERRN", "FRAU", "DR", "PROF", "MR", "MRS", "MS"]

    private static func nameTokens(_ name: String) -> Set<String> {
        Set(
            CategoryRuleEngine.normalizedKey(name)
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count > 1 && !honorifics.contains($0) }
        )
    }
}
