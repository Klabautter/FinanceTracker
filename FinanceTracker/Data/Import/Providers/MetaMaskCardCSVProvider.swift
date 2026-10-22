import Foundation

/// MetaMask Card Provider V1 (Roadmap #127–133).
/// Fixture-getrieben nach der dokumentierten Feldliste des
/// Statement-of-Transactions-Exports: merchant, date/time, fiat amount,
/// fiat currency, crypto asset, crypto amount, status, reference (#130).
struct MetaMaskCardCSVProvider: ImportProvider {
    static let providerIdentifier = "metamask_card_csv"

    private enum Columns {
        static let date = "date"
        static let time = "time"
        static let type = "type"
        static let merchant = "merchant"
        static let status = "status"
        static let fiatAmount = "fiat amount"
        static let fiatCurrency = "fiat currency"
        static let cryptoAsset = "crypto asset"
        static let cryptoAmount = "crypto amount"
        static let reference = "reference"
    }

    /// Detection-Kern: „fiat amount" + „crypto amount" + „reference" sind
    /// die eindeutige MetaMask-Signatur gegenüber generischen CSVs.
    private static let requiredHeaders: Set<String> = [
        Columns.date, Columns.type, Columns.status,
        Columns.fiatAmount, Columns.fiatCurrency,
        Columns.cryptoAmount, Columns.reference
    ]

    let identifier: String = MetaMaskCardCSVProvider.providerIdentifier
    var displayName: String { String(localized: "Kartenexport") }
    let transactionSource: TransactionSource = .metamaskCardCSV
    let fallbackCurrency: CurrencyCode

    init(fallbackCurrency: CurrencyCode = .eur) {
        self.fallbackCurrency = fallbackCurrency
    }

    func canHandle(_ file: ImportFile) async throws -> Bool {
        guard let document = try? CSVReader.parse(file.data) else { return false }
        return CSVDetection.containsAll(document.headers, required: Self.requiredHeaders)
    }

    func parse(_ file: ImportFile) async throws -> ProviderParseResult {
        let document = try CSVReader.parse(file.data)
        guard CSVDetection.containsAll(document.headers, required: Self.requiredHeaders) else {
            throw ImportError.missingColumns(
                missing: Self.requiredHeaders.sorted().filter { !CSVDetection.containsAll(document.headers, required: [$0]) }
            )
        }

        var transactions: [ImportedTransaction] = []
        var issues: [ImportRowIssue] = []

        for (index, record) in document.records.enumerated() {
            let rowIndex = index + 1

            guard let rawMoney = CSVMoneyParser.parseMoney(
                document.value(Columns.fiatAmount, in: record),
                currencyRaw: document.value(Columns.fiatCurrency, in: record),
                fallback: fallbackCurrency
            ) else {
                issues.append(ImportRowIssue(rowIndex: rowIndex, reason: String(localized: "Betrag konnte nicht erkannt werden")))
                continue
            }

            guard let date = CSVDateParser.parse(combinedDateTime(
                date: document.value(Columns.date, in: record),
                time: document.value(Columns.time, in: record)
            )) else {
                issues.append(ImportRowIssue(rowIndex: rowIndex, reason: String(localized: "Datum/Zeit konnte nicht erkannt werden")))
                continue
            }

            let statusRaw = (document.value(Columns.status, in: record) ?? "")
                .trimmingCharacters(in: .whitespaces)
                .uppercased()

            let status: TransactionStatus
            switch statusRaw {
            case "PENDING", "AUTHORIZED": status = .pending
            case "FAILED", "DECLINED", "CANCELLED": status = .cancelled
            case "REVERSED": status = .reversed
            default: status = .booked
            }

            let typeRaw = (document.value(Columns.type, in: record) ?? "")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()

            let merchant = clean(document.value(Columns.merchant, in: record))
                ?? clean(document.value(Columns.reference, in: record))
                ?? "MetaMask Card"

            let (kind, money) = Self.normalizeSemantics(type: typeRaw, amount: rawMoney)

            transactions.append(
                ImportedTransaction(
                    externalID: clean(document.value(Columns.reference, in: record)),
                    status: status,
                    kind: kind,
                    amount: money,
                    bookedAt: status == .pending ? nil : date,
                    authorizedAt: status == .pending ? date : nil,
                    rawDescription: merchant,
                    rawMerchantName: merchant,
                    merchantDisplayName: merchant,
                    paymentMethod: .cardOnline,
                    cryptoAsset: clean(document.value(Columns.cryptoAsset, in: record)),
                    cryptoAmount: CSVMoneyParser.parse(document.value(Columns.cryptoAmount, in: record))
                )
            )
        }

        return ProviderParseResult(
            totalRows: document.recordCount,
            transactions: transactions,
            issues: issues
        )
    }

    /// Sign-Semantik (#130): Exporte sind typgetrieben; Betrags-Vorzeichen
    /// wird normalisiert (Ausgaben negativ, Refund/Cashback positiv).
    static func normalizeSemantics(type rawType: String, amount: Money) -> (TransactionKind, Money) {
        switch rawType {
        case "purchase", "card_purchase", "card_spend":
            return (.purchase, Money(amount: -Swift.abs(amount.amount), currency: amount.currency))
        case "refund", "card_refund", "reversal":
            return (.refund, Money(amount: Swift.abs(amount.amount), currency: amount.currency))
        case "cashback", "reward":
            return (.cashback, Money(amount: Swift.abs(amount.amount), currency: amount.currency))
        case "fee", "gas_fee":
            return (.fee, Money(amount: -Swift.abs(amount.amount), currency: amount.currency))
        default:
            return (.unknown, amount)
        }
    }

    private func combinedDateTime(date: String?, time: String?) -> String? {
        let datePart = date?.trimmingCharacters(in: .whitespaces) ?? ""
        let timePart = time?.trimmingCharacters(in: .whitespaces) ?? ""
        if timePart.isEmpty { return datePart.isEmpty ? nil : datePart }
        return "\(datePart) \(timePart)"
    }

    private func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
