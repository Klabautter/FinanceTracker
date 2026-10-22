import Foundation
import UniformTypeIdentifiers
import SwiftUI

/// FileDocument-Wrapper für den CSV-Export (Settings → Daten).
struct TransactionsCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }

    var csv: String

    init(csv: String) {
        self.csv = csv
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            csv = String(data: data, encoding: .utf8) ?? ""
        } else {
            csv = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(csv.utf8))
    }
}

/// Baut den Export aus allen lokalen Daten (Roadmap #150).
/// WP30: Die Aufbereitung (CSV/String-Bau) läuft OFF-MAIN, der MainActor
/// sieht nur den Start der Repository-Loads und das Ergebnis-Dokument.
///
/// P2 Streaming: Transaktionen werden über `transactionPage` in Batches
/// geladen (DB-seitiges Paging via fetchOffset/fetchLimit) statt einer
/// Voll-Hydration, gleiche Spalten/Reihenfolge, gleiche Domain-API.
enum CSVExportService {
    /// Batch-Größe für den Streaming-Export (DB-Paging).
    static let exportPageSize = 1000

    static func makeDocument(dependencies: AppDependencies) async throws -> TransactionsCSVDocument {
        async let accountsTask = dependencies.accountRepository.accounts()
        async let categoriesTask = dependencies.categoryRepository.categories()
        async let tagsTask = dependencies.tagRepository.tags()

        let accounts = try await accountsTask
        let categories = try await categoriesTask
        let tags = try await tagsTask
        let input = TransactionsCSVExporter.Input(
            transactions: [],
            accounts: accounts,
            categories: categories,
            tags: tags
        )

        let csv = try await buildCSVStreaming(dependencies: dependencies, input: input)
        return TransactionsCSVDocument(csv: csv)
    }

    /// Batched CSV-Aufbau: Pages sind global nach displayDate sortiert
    /// (Store-Sortierung = Export-Sortierung), daher kein Re-Sort. Läuft
    /// nicht auf dem MainActor (Repository-Calls sind ModelActor-gebunden,
    /// String-Bau detached).
    private static func buildCSVStreaming(
        dependencies: AppDependencies,
        input: TransactionsCSVExporter.Input
    ) async throws -> String {
        let exporter = TransactionsCSVExporter(input: input)
        let repository = dependencies.transactionRepository
        let pageSize = Self.exportPageSize
        // Paging-Loop (await suspends; kein MainActor-Block).
        var lines = [TransactionsCSVExporter.header.joined(separator: ",")]
        lines.reserveCapacity(1024)
        let isoFormatter = TransactionsCSVExporter.dayFormatter()
        var offset = 0
        while true {
            let page = try await repository.transactionPage(
                matching: TransactionQuery(),
                sort: .dateAscending,
                offset: offset,
                limit: pageSize
            )
            for txn in page.transactions {
                lines.append(exporter.csvRow(for: txn, isoFormatter: isoFormatter))
            }
            if !page.hasMore || page.transactions.isEmpty { break }
            offset += page.transactions.count
        }
        let finishedLines = lines
        return await Task.detached(priority: .userInitiated) {
            PerfSignpost.measure("CSVExport") {
                finishedLines.joined(separator: "\r\n") + "\r\n"
            }
        }.value
    }

    /// Off-main: Der String-Bau für große Exporte blockiert nicht den MainActor.
    private static func buildCSV(input: TransactionsCSVExporter.Input) async throws -> String {
        let exporter = TransactionsCSVExporter(input: input)
        let transactions = input.transactions
        return await Task.detached(priority: .userInitiated) {
            PerfSignpost.measure("CSVExport") {
                exporter.makeCSV(transactions: transactions)
            }
        }.value
    }

    static func defaultFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "FinanceTracker-Export-\(formatter.string(from: now)).csv"
    }
}
