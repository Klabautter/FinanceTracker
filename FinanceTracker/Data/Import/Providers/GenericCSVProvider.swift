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
            "price", "preis", "kurs", "shares", "stuck", "rate", "datum", "date"
        ]

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
            currencyColumn: find(["wahrung", "waehrung", "currency", "ccy", "cur"], excluding: ["original", "fremd"]),
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
            ).flatMap { $0 == date ? nil : $0 }
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

    let identifier: String = GenericCSVProvider.providerIdentifier
    var displayName: String { String(localized: "Tabelle mit Buchungen") }
    let transactionSource: TransactionSource = .genericCSV
    let fallbackCurrency: CurrencyCode

    init(fallbackCurrency: CurrencyCode = .eur, forcedMapping: GenericCSVMapping? = nil) {
        self.fallbackCurrency = fallbackCurrency
        self.forcedMapping = forcedMapping
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

            guard let bookedDate = CSVDateParser.parse(value(mapping.dateColumn), monthFirst: monthFirst)
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

            transactions.append(
                ImportedTransaction(
                    externalID: clean(value(mapping.externalIDColumn)),
                    status: status,
                    amount: money,
                    bookedAt: bookedDate,
                    authorizedAt: nil,
                    rawDescription: rawDescription,
                    rawMerchantName: rawMerchant,
                    merchantDisplayName: rawMerchant ?? rawDescription,
                    suggestedCategoryID: Self.isSecuritiesTrade(clean(value(mapping.typeColumn)))
                        ? Category.investments.id
                        : nil,
                    balanceAfter: clean(value(mapping.balanceColumn)).flatMap {
                        CSVMoneyParser.parse($0, decimalSeparator: decimalSeparator)
                    }
                )
            )
        }
        return ProviderParseResult(
            totalRows: document.recordCount,
            transactions: transactions,
            issues: issues
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
