import Foundation

struct EtherFiCSVProvider: ImportProvider {
    static let providerIdentifier = "etherfi_cash_csv"

    private enum Columns {
        static let timestamp = "timestamp"
        static let type = "type"
        static let description = "description"
        static let status = "status"
        static let amount = "amount"
        static let currency = "currency"
        static let cashbackEarned = "cashback earned"
        static let cashbackCurrency = "cashback currency"
        static let originalAmount = "original amount"
        static let originalCurrency = "original currency"
        /// Optional: Branchenangabe des Händlers (nicht jeder Export hat sie).
        static let category = "category"
    }

    private static let requiredHeaders: Set<String> = [
        Columns.timestamp, Columns.type, Columns.description,
        Columns.status, Columns.amount, Columns.currency
    ]

    let identifier: String = EtherFiCSVProvider.providerIdentifier
    var displayName: String { String(localized: "Kartenexport mit Cashback") }
    let transactionSource: TransactionSource = .etherFiCashCSV
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
                document.value(Columns.amount, in: record),
                currencyRaw: document.value(Columns.currency, in: record),
                fallback: fallbackCurrency
            ) else {
                issues.append(ImportRowIssue(rowIndex: rowIndex, reason: String(localized: "Betrag konnte nicht erkannt werden")))
                continue
            }

            guard let date = CSVDateParser.parse(document.value(Columns.timestamp, in: record)) else {
                issues.append(ImportRowIssue(rowIndex: rowIndex, reason: String(localized: "Zeitstempel konnte nicht erkannt werden")))
                continue
            }

            let statusRaw = (document.value(Columns.status, in: record) ?? "")
                .trimmingCharacters(in: .whitespaces)
                .uppercased()

            let status: TransactionStatus
            switch statusRaw {
            case "PENDING": status = .pending
            case "CANCELLED": status = .cancelled
            case "REVERSED": status = .reversed
            default: status = .booked
            }

            let typeRaw = (document.value(Columns.type, in: record) ?? "")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()

            let rawDescription = clean(document.value(Columns.description, in: record))

            let (kind, money) = Self.normalizeSemantics(type: typeRaw, amount: rawMoney)

            transactions.append(
                ImportedTransaction(
                    status: status,
                    kind: kind,
                    amount: money,
                    bookedAt: status == .pending ? nil : date,
                    authorizedAt: status == .pending ? date : nil,
                    rawDescription: rawDescription,
                    rawMerchantName: rawDescription,
                    merchantDisplayName: rawDescription,
                    cryptoAsset: nil,
                    cryptoAmount: nil,
                    cashbackAmount: CSVMoneyParser.parse(document.value(Columns.cashbackEarned, in: record)),
                    cashbackCurrency: document.value(Columns.cashbackCurrency, in: record)
                        .map { CurrencyCode($0.trimmingCharacters(in: .whitespaces)) },
                    originalAmount: CSVMoneyParser.parse(document.value(Columns.originalAmount, in: record)),
                    originalCurrency: document.value(Columns.originalCurrency, in: record)
                        .map { CurrencyCode($0.trimmingCharacters(in: .whitespaces)) },
                    suggestedCategoryID: EtherFiCategoryMapper.categoryID(
                        for: document.value(Columns.category, in: record)
                    )
                )
            )
        }
        return ProviderParseResult(
            totalRows: document.recordCount,
            transactions: transactions,
            issues: issues
        )
    }

    static func normalizeSemantics(type rawType: String, amount: Money) -> (TransactionKind, Money) {
        switch rawType {
        case "card_spend":
            return (.purchase, Money(amount: -Swift.abs(amount.amount), currency: amount.currency))
        case "refund", "card_refund", "reversal":
            return (.refund, Money(amount: Swift.abs(amount.amount), currency: amount.currency))
        case "cashback":
            return (.cashback, Money(amount: Swift.abs(amount.amount), currency: amount.currency))
        case "fee":
            return (.fee, Money(amount: -Swift.abs(amount.amount), currency: amount.currency))
        default:
            return (.unknown, amount)
        }
    }

    private func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
