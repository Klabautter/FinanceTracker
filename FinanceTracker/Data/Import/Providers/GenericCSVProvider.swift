import Foundation

/// Welche Spalte einer Tabelle welche Bedeutung hat. Die Namen sind die
/// Überschriften, wie sie in der Datei stehen.
struct GenericCSVMapping: Sendable, Equatable {
    let dateColumn: String
    /// Vorzeichenbehafteter Betrag. Leer, wenn die Datei stattdessen
    /// getrennte Soll-/Haben-Spalten führt.
    let amountColumn: String
    var descriptionColumn: String?
    var merchantColumn: String?
    var currencyColumn: String?
    var externalIDColumn: String?
    /// Getrennte Spalten für Abgänge und Zugänge (Soll/Haben).
    var debitColumn: String?
    var creditColumn: String?
    var statusColumn: String?
    var typeColumn: String?
    /// Kontostand nach der Buchung.
    var balanceColumn: String?
    /// Soll/Haben-Kennzeichen zu einem vorzeichenlosen Betrag („S"/„H").
    var signColumn: String?
    /// Zweites Datum, falls das erste leer ist (z. B. „Completed Date" fehlt
    /// bei ausstehenden Revolut-Zahlungen, „Started Date" ist da).
    var fallbackDateColumn: String?
    /// Uhrzeit in eigener Spalte neben dem Datum.
    var timeColumn: String?
    /// Gebühr zur Buchung (wird eine eigene Gebührenbuchung).
    var feeColumn: String?
    var feeCurrencyColumn: String?
    /// Betrag in der Währung des Händlers, z. B. Euro neben einem USD-Konto.
    var originalAmountColumn: String?
    var originalCurrencyColumn: String?
    var cashbackColumn: String?
    var cashbackCurrencyColumn: String?
    /// Branchenangabe des Händlers (Kartenexporte, teils mit MCC).
    var merchantCategoryColumn: String?
    var cryptoAssetColumn: String?
    var cryptoAmountColumn: String?

    private enum Match {
        /// Nur die exakte Überschrift.
        case exact
        /// Exakt, sonst als Wortanfang, sonst irgendwo enthalten.
        case loose
    }

    static func detect(in document: CSVDocument) -> GenericCSVMapping? {
        let keys = document.headers.map(CSVDetection.comparisonKey)

        func find(_ candidates: [String], _ match: Match = .loose, excluding: [String] = []) -> String? {
            func allowed(_ key: String) -> Bool {
                !key.isEmpty && !excluding.contains { key.contains($0) }
            }
            for candidate in candidates {
                if let index = keys.firstIndex(where: { $0 == candidate }) {
                    return document.headers[index]
                }
            }
            guard match == .loose else { return nil }
            for candidate in candidates {
                if let index = keys.firstIndex(where: { allowed($0) && $0.hasPrefix(candidate + " ") }) {
                    return document.headers[index]
                }
            }
            for candidate in candidates {
                if let index = keys.firstIndex(where: { allowed($0) && $0.contains(candidate) }) {
                    return document.headers[index]
                }
            }
            return nil
        }

        // Nebenbeträge dürfen nicht als Buchungsbetrag durchgehen.
        let notTheAmount = [
            "original", "fremd", "saldo", "balance", "fee", "gebuhr", "tax", "steuer",
            "price", "preis", "kurs", "shares", "stuck", "rate", "datum", "date",
            "local", "lokal", "cashback", "crypto", "currency", "wahrung"
        ]
        // Währungsspalten von Nebenbeträgen sind nicht die Kontowährung.
        let notTheCurrency = ["original", "fremd", "local", "lokal", "fee", "gebuhr", "cashback", "crypto"]

        guard let date = find([
            "buchungstag", "buchungsdatum", "datum", "date", "booking date", "transaction date",
            "datetime", "timestamp", "completed date", "started date",
            "valuta", "valutadatum", "wertstellung", "value date"
        ]) else {
            return nil
        }

        // Mehrdeutige Wörter gelten nur als ganze Überschrift („Wert" steckt
        // sonst auch in „Wertstellung").
        let amount = find(["betrag", "amount", "umsatz"], excluding: notTheAmount)
            ?? find(["value", "wert", "summe", "total"], .exact)
        let debit = find(
            ["soll", "debit", "belastung", "ausgang", "zahlungsausgang", "ausgaben", "soll eur", "debit amount", "betrag soll", "money out", "paid out"],
            .exact
        )
        let credit = find(
            ["haben", "credit", "gutschrift", "eingang", "zahlungseingang", "einnahmen", "haben eur", "credit amount", "betrag haben", "money in", "paid in"],
            .exact
        )
        let hasSplitAmounts = debit != nil && credit != nil
        guard amount != nil || hasSplitAmounts else { return nil }

        return GenericCSVMapping(
            dateColumn: date,
            amountColumn: amount ?? "",
            descriptionColumn: find([
                "verwendungszweck", "buchungstext", "beschreibung", "description", "memo", "purpose",
                "details", "payment reference", "text", "notiz", "note"
            ]),
            merchantColumn: find(
                [
                    "empfanger", "empfaenger", "begunstigter", "beguenstigter", "zahlungsempfanger",
                    "auftraggeber", "name zahlungsbeteiligter", "counterparty name", "counterparty",
                    "merchant", "payee", "partner name", "partnername", "name"
                ],
                excluding: ["account", "konto", "bank", "user", "holder", "inhaber", "iban", "bic"]
            ),
            currencyColumn: find(["wahrung", "waehrung", "currency", "ccy", "cur"], excluding: notTheCurrency),
            // Nur eindeutige Überschriften: Eine falsch erkannte ID-Spalte
            // (z. B. Gläubiger-ID) ließe verschiedene Buchungen als Duplikate
            // zusammenfallen.
            externalIDColumn: find([
                "id", "transaction id", "transaktions id", "transaktionsnummer", "umsatz id",
                "reference", "referenz", "buchungsreferenz", "kundenreferenz"
            ], .exact),
            debitColumn: amount == nil ? debit : nil,
            creditColumn: amount == nil ? credit : nil,
            statusColumn: find(["status", "state", "buchungsstatus"], .exact),
            typeColumn: find(
                ["type", "typ", "transaction type", "transaktionstyp", "umsatzart", "buchungsart", "art"],
                .exact
            ),
            balanceColumn: find(["saldo", "kontostand", "balance", "saldo nach buchung"]),
            signColumn: find(
                ["s h", "soll haben", "soll oder haben", "sh", "debit credit", "credit debit", "dr cr", "cr dr",
                 "credit debit indicator", "debit credit indicator", "cd indicator"],
                .exact
            ),
            fallbackDateColumn: find(
                ["started date", "transaction date", "buchungsdatum", "buchungstag", "datum", "date",
                 "valuta", "valutadatum", "wertstellung", "value date", "post date", "posting date"],
                .exact,
                excluding: []
            ).flatMap { $0 == date ? nil : $0 },
            timeColumn: find(["time", "uhrzeit", "zeit", "buchungszeit", "transaction time"], .exact),
            feeColumn: find(["fee", "fees", "gebuhr", "gebuhren", "entgelt", "fee amount", "gebuhrenbetrag"], .exact),
            feeCurrencyColumn: find(["fee currency", "gebuhr wahrung", "gebuhrenwahrung"], .exact),
            originalAmountColumn: find([
                "original amount", "originalbetrag", "betrag original", "amount local", "local amount",
                "foreign amount", "fremdwahrungsbetrag", "betrag in fremdwahrung", "fiat amount local"
            ], .exact),
            originalCurrencyColumn: find([
                "original currency", "originalwahrung", "amount local currency", "local currency",
                "foreign currency", "fremdwahrung"
            ], .exact),
            cashbackColumn: find(["cashback earned", "cashback", "cashback amount", "cashback betrag"], .exact),
            cashbackCurrencyColumn: find(["cashback currency", "cashback wahrung"], .exact),
            merchantCategoryColumn: find(["category", "merchant category", "mcc", "branche", "kategorie"], .exact),
            cryptoAssetColumn: find(["crypto asset"], .exact),
            cryptoAmountColumn: find(["crypto amount"], .exact)
        )
    }

    /// Passt die Zuordnung zu den Daten darunter? Mindestens eine der ersten
    /// Zeilen muss ein lesbares Datum und einen lesbaren Betrag haben:
    /// sonst war es eine Kopfzeile wie „Datei erstellt am …".
    func matchesData(in document: CSVDocument) -> Bool {
        let sample = document.records.prefix(8).filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !sample.isEmpty else { return true }
        let monthFirst = CSVDateParser.prefersMonthFirst(in: sample.compactMap { document.value(dateColumn, in: $0) })
        return sample.contains { record in
            let dateOK = [dateColumn, fallbackDateColumn].compactMap { $0 }.contains {
                CSVDateParser.parse(document.value($0, in: record), monthFirst: monthFirst) != nil
            }
            let amountColumns = amountColumn.isEmpty ? [debitColumn, creditColumn].compactMap { $0 } : [amountColumn]
            let amountOK = amountColumns.contains { CSVMoneyParser.parse(document.value($0, in: record)) != nil }
            return dateOK && amountOK
        }
    }

    /// Sucht die Überschriftenzeile: die erste der oberen Zeilen, in der sich
    /// Datum und Betrag erkennen lassen. Kopfzeilen davor (Kontoname,
    /// Zeitraum, Saldo) werden übersprungen.
    static func locate(in rows: [[String]]) -> (document: CSVDocument, mapping: GenericCSVMapping)? {
        for index in rows.indices.prefix(30) {
            let document = CSVDocument(
                headers: rows[index].map { $0.trimmingCharacters(in: .whitespaces) },
                records: Array(rows[(index + 1)...])
            )
            if let mapping = detect(in: document), mapping.matchesData(in: document) {
                return (document, mapping)
            }
        }
        return nil
    }
}

/// Liest beliebige Kontoexporte als Tabelle: Spalten werden an ihren
/// Überschriften erkannt, nicht an der Bank.
struct GenericCSVProvider: ImportProvider {
    static let providerIdentifier = "generic_csv"

    private let forcedMapping: GenericCSVMapping?
    /// Vom Nutzer festgelegte Bedeutung unbekannter Buchungsarten
    /// (Schlüssel: `TransactionTypeVocabulary.normalizedKey`). Hat Vorrang
    /// vor dem Wörterbuch (#22).
    private let typeMeanings: [String: TransactionTypeMeaning]

    let identifier: String = GenericCSVProvider.providerIdentifier
    var displayName: String { String(localized: "Tabelle mit Buchungen") }
    let transactionSource: TransactionSource = .genericCSV
    let fallbackCurrency: CurrencyCode

    init(
        fallbackCurrency: CurrencyCode = .eur,
        forcedMapping: GenericCSVMapping? = nil,
        typeMeanings: [String: TransactionTypeMeaning] = [:]
    ) {
        self.fallbackCurrency = fallbackCurrency
        self.forcedMapping = forcedMapping
        self.typeMeanings = typeMeanings
    }

    func with(typeMeanings: [String: TransactionTypeMeaning]) -> GenericCSVProvider {
        GenericCSVProvider(fallbackCurrency: fallbackCurrency, forcedMapping: forcedMapping, typeMeanings: typeMeanings)
    }

    func canHandle(_ file: ImportFile) async throws -> Bool {
        if forcedMapping != nil { return true }
        guard let rows = try? CSVReader.parseRows(file.data) else { return false }
        return GenericCSVMapping.locate(in: rows) != nil
    }

    func resolveMapping(in document: CSVDocument) -> GenericCSVMapping? {
        forcedMapping ?? GenericCSVMapping.detect(in: document)
    }

    func parse(_ file: ImportFile) async throws -> ProviderParseResult {
        let document: CSVDocument
        let mapping: GenericCSVMapping
        if let forcedMapping {
            // Manuelle Zuordnung bezieht sich auf die erste Zeile der Datei.
            document = try CSVReader.parse(file.data)
            mapping = forcedMapping
        } else {
            guard let located = GenericCSVMapping.locate(in: try CSVReader.parseRows(file.data)) else {
                throw ImportError.missingColumns(missing: ["Datum-Spalte", "Betrag-Spalte"])
            }
            (document, mapping) = located
        }

        var transactions: [ImportedTransaction] = []
        var issues: [ImportRowIssue] = []

        // Zahl- und Datumsformat gelten für die ganze Datei: „2.000" ist in
        // einer Datei mit „-12,30" zweitausend, „10/15/2026" heißt Oktober.
        let amountSamples = [mapping.amountColumn, mapping.debitColumn, mapping.creditColumn, mapping.balanceColumn]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .flatMap { column in document.records.compactMap { document.value(column, in: $0) } }
        let decimalSeparator = CSVMoneyParser.decimalSeparator(in: amountSamples)
        let monthFirst = CSVDateParser.prefersMonthFirst(
            in: document.records.compactMap { document.value(mapping.dateColumn, in: $0) }
        )
        // Führt die Datei Vorzeichen (mindestens ein negativer Betrag oder
        // Soll/Haben getrennt), bestimmt das Vorzeichen die Richtung. Sonst
        // sind alle Beträge positiv und die Art sagt, wohin das Geld geht.
        let amountsAreSigned = mapping.debitColumn != nil || mapping.signColumn != nil
            || document.records.contains { record in
                guard !mapping.amountColumn.isEmpty,
                      let parsed = CSVMoneyParser.parse(
                          document.value(mapping.amountColumn, in: record),
                          decimalSeparator: decimalSeparator
                      ) else { return false }
                return parsed < 0
            }
        var unknownTypes: [String: (label: String, count: Int)] = [:]

        for (index, record) in document.records.enumerated() {
            let rowIndex = index + 1
            func value(_ column: String?) -> String? {
                column.flatMap { $0.isEmpty ? nil : document.value($0, in: record) }
            }

            let money: Money
            switch amount(in: record, document: document, mapping: mapping, decimalSeparator: decimalSeparator) {
            case .success(let parsed): money = parsed
            case .failure(let issue):
                issues.append(ImportRowIssue(rowIndex: rowIndex, reason: issue.reason))
                continue
            }

            let dateText = [clean(value(mapping.dateColumn)), clean(value(mapping.timeColumn))]
                .compactMap { $0 }
                .joined(separator: " ")
            guard let bookedDate = CSVDateParser.parse(dateText.isEmpty ? nil : dateText, monthFirst: monthFirst)
                    ?? CSVDateParser.parse(value(mapping.dateColumn), monthFirst: monthFirst)
                    ?? CSVDateParser.parse(value(mapping.fallbackDateColumn), monthFirst: monthFirst) else {
                issues.append(ImportRowIssue(rowIndex: rowIndex, reason: String(localized: "Datum konnte nicht erkannt werden")))
                continue
            }

            let statusRaw = clean(value(mapping.statusColumn))
            guard let status = Self.status(from: statusRaw) else {
                issues.append(ImportRowIssue(rowIndex: rowIndex, reason: String(localized: "Status „\(statusRaw ?? "")“ ist unbekannt")))
                continue
            }

            let rawMerchant = clean(value(mapping.merchantColumn))
            let rawDescription = clean(value(mapping.descriptionColumn))
            let rawType = clean(value(mapping.typeColumn))

            // Art der Buchung: Nutzerentscheidung vor Wörterbuch; Unbekanntes
            // bleibt beim Vorzeichen und wird der Vorschau gemeldet.
            var kind = TransactionKind.unknown
            var signedMoney = money
            if let typeKey = TransactionTypeVocabulary.normalizedKey(rawType) {
                if let meaning = typeMeanings[typeKey] ?? TransactionTypeVocabulary.meaning(of: rawType) {
                    if !amountsAreSigned {
                        signedMoney = meaning.signed(money)
                        kind = meaning.kind
                    } else if meaning.agrees(withSignOf: money) {
                        kind = meaning.kind
                    }
                } else if !Self.isSecuritiesTrade(rawType) {
                    // Wertpapierhandel ist erkannt (Kategorie Geldanlage),
                    // die Richtung gibt das Vorzeichen: keine Rückfrage.
                    let known = unknownTypes[typeKey]
                    unknownTypes[typeKey] = (known?.label ?? rawType ?? typeKey, (known?.count ?? 0) + 1)
                }
            }

            let originalCurrency = clean(value(mapping.originalCurrencyColumn)).map(CurrencyCode.init)
            let cashbackCurrency = clean(value(mapping.cashbackCurrencyColumn)).map(CurrencyCode.init)
            let merchantCategoryID = MerchantCategoryMapper.categoryID(for: clean(value(mapping.merchantCategoryColumn)))
            let externalID = clean(value(mapping.externalIDColumn))

            transactions.append(
                ImportedTransaction(
                    externalID: externalID,
                    status: status,
                    kind: kind,
                    amount: signedMoney,
                    bookedAt: status == .pending ? nil : bookedDate,
                    authorizedAt: status == .pending ? bookedDate : nil,
                    rawDescription: rawDescription,
                    rawMerchantName: rawMerchant,
                    merchantDisplayName: rawMerchant ?? rawDescription,
                    cryptoAsset: clean(value(mapping.cryptoAssetColumn)),
                    cryptoAmount: clean(value(mapping.cryptoAmountColumn)).flatMap { CSVMoneyParser.parse($0) },
                    cashbackAmount: clean(value(mapping.cashbackColumn))
                        .flatMap { CSVMoneyParser.parse($0, decimalSeparator: decimalSeparator) }
                        .flatMap { $0 == 0 ? nil : abs($0) },
                    cashbackCurrency: cashbackCurrency,
                    originalAmount: clean(value(mapping.originalAmountColumn))
                        .flatMap { CSVMoneyParser.parse($0, decimalSeparator: decimalSeparator) }
                        .map { abs($0) },
                    originalCurrency: originalCurrency,
                    suggestedCategoryID: Self.isSecuritiesTrade(rawType) ? Category.investments.id : merchantCategoryID,
                    balanceAfter: clean(value(mapping.balanceColumn)).flatMap {
                        CSVMoneyParser.parse($0, decimalSeparator: decimalSeparator)
                    }
                )
            )

            // Gebühr in eigener Spalte: eigene Gebührenbuchung, damit sie in
            // Ausgaben und Saldo auftaucht. Unlesbar heißt Zeilenhinweis (#17).
            if let feeRaw = clean(value(mapping.feeColumn)) {
                guard let fee = CSVMoneyParser.parse(feeRaw, decimalSeparator: decimalSeparator) else {
                    issues.append(ImportRowIssue(rowIndex: rowIndex, reason: String(localized: "Gebühr konnte nicht erkannt werden")))
                    continue
                }
                if fee != 0 {
                    let feeCurrency = clean(value(mapping.feeCurrencyColumn)).map(CurrencyCode.init) ?? money.currency
                    let label = [String(localized: "Gebühr"), rawMerchant ?? rawDescription].compactMap { $0 }.joined(separator: ": ")
                    transactions.append(
                        ImportedTransaction(
                            externalID: externalID.map { $0 + "-fee" },
                            status: status,
                            kind: .fee,
                            amount: Money(amount: -abs(fee), currency: feeCurrency),
                            bookedAt: status == .pending ? nil : bookedDate,
                            authorizedAt: status == .pending ? bookedDate : nil,
                            rawDescription: label,
                            rawMerchantName: label,
                            merchantDisplayName: label
                        )
                    )
                }
            }
        }
        return ProviderParseResult(
            totalRows: document.recordCount,
            transactions: transactions,
            issues: issues,
            unknownTypes: unknownTypes
                .map { UnknownTransactionType(key: $0.key, label: $0.value.label, count: $0.value.count) }
                .sorted { $0.count > $1.count }
        )
    }

    // MARK: - Betrag

    private struct AmountIssue: Error {
        let reason: String
    }

    private func amount(
        in record: [String],
        document: CSVDocument,
        mapping: GenericCSVMapping,
        decimalSeparator: Character?
    ) -> Result<Money, AmountIssue> {
        let currencyRaw = mapping.currencyColumn.flatMap { document.value($0, in: record) }

        if let debitColumn = mapping.debitColumn, let creditColumn = mapping.creditColumn {
            let debitRaw = clean(document.value(debitColumn, in: record))
            let creditRaw = clean(document.value(creditColumn, in: record))
            let debit = debitRaw.flatMap { CSVMoneyParser.parse($0, decimalSeparator: decimalSeparator) }
            let credit = creditRaw.flatMap { CSVMoneyParser.parse($0, decimalSeparator: decimalSeparator) }
            // Ein gefülltes, aber unlesbares Feld ist ein Fehler, nie 0 (#17).
            if (debitRaw != nil && debit == nil) || (creditRaw != nil && credit == nil) {
                return .failure(AmountIssue(reason: String(localized: "Betrag konnte nicht erkannt werden")))
            }
            let signed: Decimal
            switch (debit ?? 0, credit ?? 0) {
            case (0, 0) where debitRaw == nil && creditRaw == nil:
                return .failure(AmountIssue(reason: String(localized: "Betrag konnte nicht erkannt werden")))
            case (let out, 0): signed = -abs(out)
            case (0, let incoming): signed = abs(incoming)
            default:
                return .failure(AmountIssue(reason: String(localized: "Soll und Haben sind beide gefüllt")))
            }
            guard let money = CSVMoneyParser.parseMoney(
                NSDecimalNumber(decimal: signed).stringValue,
                currencyRaw: currencyRaw,
                fallback: fallbackCurrency
            ) else {
                return .failure(AmountIssue(reason: String(localized: "Betrag konnte nicht erkannt werden")))
            }
            return .success(money)
        }

        guard var money = CSVMoneyParser.parseMoney(
            document.value(mapping.amountColumn, in: record),
            currencyRaw: currencyRaw,
            fallback: fallbackCurrency,
            decimalSeparator: decimalSeparator
        ) else {
            return .failure(AmountIssue(reason: String(localized: "Betrag konnte nicht erkannt werden")))
        }
        // Vorzeichenloser Betrag mit eigener Soll/Haben-Spalte.
        if let signColumn = mapping.signColumn, let marker = clean(document.value(signColumn, in: record)) {
            switch marker == "-" ? "S" : marker == "+" ? "H" : CategoryRuleEngine.normalizedKey(marker) {
            case "S", "SOLL", "D", "DR", "DEBIT", "DBIT":
                money = Money(amount: -abs(money.amount), currency: money.currency)
            case "H", "HABEN", "C", "CR", "CREDIT", "CRDT":
                money = Money(amount: abs(money.amount), currency: money.currency)
            default:
                return .failure(AmountIssue(reason: String(localized: "Soll/Haben-Kennzeichen „\(marker)“ ist unbekannt")))
            }
        }
        return .success(money)
    }

    // MARK: - Status und Art

    private static let bookedStatuses: Set<String> = [
        "BOOKED", "GEBUCHT", "VERBUCHT", "EXECUTED", "AUSGEFUHRT", "AUSGEFUEHRT", "SETTLED", "COMPLETED",
        "COMPLETE", "ABGESCHLOSSEN", "CLEARED", "POSTED", "DONE", "SUCCESS", "SUCCESSFUL", "ERFOLGREICH",
        "OK", "PAID", "BEZAHLT", "FINAL"
    ]
    private static let pendingStatuses: Set<String> = [
        "PENDING", "VORGEMERKT", "RESERVED", "RESERVIERT", "OPEN", "OFFEN", "PROCESSING", "IN BEARBEITUNG",
        "AUTHORIZED", "AUTHORISED", "AUSSTEHEND"
    ]
    private static let cancelledStatuses: Set<String> = [
        "CANCELLED", "CANCELED", "STORNIERT", "REJECTED", "ABGELEHNT", "DECLINED", "FAILED",
        "FEHLGESCHLAGEN", "EXPIRED", "ABGELAUFEN"
    ]
    private static let reversedStatuses: Set<String> = ["REVERSED", "REVERTED", "RUCKGEBUCHT", "RUECKGEBUCHT"]

    /// Ohne Statusspalte gilt die Zeile als gebucht. Ein vorhandener, aber
    /// unbekannter Status ergibt `nil`: er wird nicht geraten (#17).
    static func status(from raw: String?) -> TransactionStatus? {
        guard let raw else { return .booked }
        let key = CategoryRuleEngine.normalizedKey(raw)
        if key.isEmpty || bookedStatuses.contains(key) { return .booked }
        if pendingStatuses.contains(key) { return .pending }
        if cancelledStatuses.contains(key) { return .cancelled }
        if reversedStatuses.contains(key) { return .reversed }
        return nil
    }

    /// Wertpapierkäufe und -verkäufe: Das Geld verlässt das Konto bzw. kommt
    /// zurück, also zählen sie als Ausgabe/Einnahme: in der eigenen
    /// Kategorie „Geldanlage", damit sie sich vom Alltag trennen lassen
    /// (Nutzer-Entscheid 13.10.2026).
    static func isSecuritiesTrade(_ rawType: String?) -> Bool {
        guard let rawType else { return false }
        let key = CategoryRuleEngine.normalizedKey(rawType)
        let tokens = Set(key.split(separator: " ").map(String.init))
        let tradeWords: Set<String> = [
            "BUY", "SELL", "KAUF", "VERKAUF", "SPARPLAN", "HANDEL", "TRADE", "TRADING", "WERTPAPIERKAUF", "WERTPAPIERVERKAUF",
            "WERTPAPIERORDER"
        ]
        return !tokens.isDisjoint(with: tradeWords) || CategoryRuleEngine.containsTokenSequence(key, "SAVINGS PLAN")
    }

    private func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
