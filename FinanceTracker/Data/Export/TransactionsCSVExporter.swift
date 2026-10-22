import Foundation

/// CSV-Export (Roadmap #150): Maschinenlesbares Format (Punkt-Dezimal,
/// ISO-8601, RFC-4180-Escaping). Spalten laut Plan #150.
///
/// P2-Entscheid (minimal, #34): Gruppenanteile (`SharedExpenseShare`) sind
/// bewusst NICHT als Spalte enthalten. Begründung: Anteile sind ein
/// User-Sidecar je Transaktion (N Zeilen pro Transaktion, #27) und lassen
/// sich nicht ohne Denormalisierung/Bruch der 1-Zeile-pro-Transaktion in
/// das flache Format pressen. Sie sind vollständig im versionierten
/// `.ftbackup` enthalten; der CSV bleibt die reine Transaktions-Tabelle.
struct TransactionsCSVExporter: Sendable {
    struct Input: Sendable {
        let transactions: [Transaction]
        let accounts: [Account]
        let categories: [Category]
        let tags: [Tag]

        init(
            transactions: [Transaction],
            accounts: [Account],
            categories: [Category],
            tags: [Tag]
        ) {
            self.transactions = transactions
            self.accounts = accounts
            self.categories = categories
            self.tags = tags
        }
    }

    static let header = [
        "Date", "Merchant", "Description", "Amount", "Currency",
        "Account", "Category", "Tags", "Note", "Status", "Kind",
        "Reviewed", "Excluded", "Source"
    ]

    private let accountsByID: [UUID: Account]
    private let categoriesByID: [UUID: Category]
    private let tagsByID: [UUID: Tag]

    init(input: Input) {
        accountsByID = Dictionary(uniqueKeysWithValues: input.accounts.map { ($0.id, $0) })
        categoriesByID = Dictionary(uniqueKeysWithValues: input.categories.map { ($0.id, $0) })
        tagsByID = Dictionary(uniqueKeysWithValues: input.tags.map { ($0.id, $0) })
    }

    init(dependencies: AppDependencies) {
        self.init(input: Input(transactions: [], accounts: [], categories: [], tags: []))
    }

    func makeCSV(transactions: [Transaction]) -> String {
        let sorted = transactions.sorted { $0.displayDate < $1.displayDate }
        var lines = [Self.header.joined(separator: ",")]

        // WP38: Ein Formatter für alle Zeilen, der ISO8601-Init pro Zeile
        // dominierte die Exportzeit bei 50k Rows (6.3s).
        let isoFormatter = TransactionsCSVExporter.dayFormatter()

        for txn in sorted {
            lines.append(csvRow(for: txn, isoFormatter: isoFormatter))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// P2 Streaming-Export: Einzelne Zeile für batched Exporte (gleiche
    /// Spalten/Escaping wie `makeCSV`; Aufrufer liefert global sortierte
    /// Pages, sodass kein Re-Sort nötig ist).
    func csvRow(for txn: Transaction, isoFormatter: ISO8601DateFormatter) -> String {
        let account = accountsByID[txn.accountID]
        let category = txn.categoryID.flatMap { categoriesByID[$0] }
        let tagNames = (txn.tagIDs ?? []).compactMap { tagsByID[$0]?.name }

        let row: [String] = [
            isoFormatter.string(from: txn.displayDate),
            txn.effectiveMerchantName,
            txn.rawDescription ?? "",
            "\(txn.amount.amount)",
            txn.amount.currency.rawValue,
            account?.name ?? "",
            category?.name ?? "",
            tagNames.joined(separator: "; "),
            txn.note ?? "",
            txn.status.rawValue,
            txn.kind.rawValue,
            txn.reviewed ? "true" : "false",
            txn.excludedFromAnalytics ? "true" : "false",
            txn.source.rawValue
        ]
        return row.map(Self.escape).joined(separator: ",")
    }

    /// Datum ohne Uhrzeit („2026-09-01") in der Zeitzone der App, so wie
    /// es in der Liste steht und wie Tabellenprogramme es direkt verstehen.
    static func dayFormatter(timeZone: TimeZone = .current) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = timeZone
        return formatter
    }

    /// RFC 4180: Felder mit Komma, Anführungszeichen oder Zeilenumbruch
    /// in doppelte Anführungszeichen; doppelte Quotes verdoppeln.
    static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
