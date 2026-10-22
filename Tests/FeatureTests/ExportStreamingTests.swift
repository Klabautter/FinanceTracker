import Foundation
import Testing

@testable import FinanceTracker

@Suite("ExportStreaming")
struct ExportStreamingTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func seed(_ dependencies: AppDependencies, count: Int) async throws -> [Transaction] {
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        var txns: [Transaction] = []
        for index in 0..<count {
            let date = calendar.date(byAdding: .day, value: index % 60, to: base)!
            txns.append(Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: "stream-\(index)",
                status: .booked,
                kind: .purchase,
                amount: Money(amount: Decimal(-(100 + index)), currency: .eur),
                bookedAt: date,
                rawDescription: "Händler \(index)",
                rawMerchantName: "Händler \(index)",
                merchantDisplayName: "Händler \(index)"
            ))
        }
        for start in stride(from: 0, to: txns.count, by: 500) {
            try await dependencies.transactionRepository.upsert(
                Array(txns[start..<min(start + 500, txns.count)])
            )
        }
        return txns
    }

    @Test("Paged Backup-Load ist vollständig (2500 über 500er-Pages)")
    func pagedBackupLoadComplete() async throws {
        let dependencies = try makeDependencies()
        _ = try await seed(dependencies, count: 2500)
        let paged = try await BackupService.pagedAllTransactions(
            repository: dependencies.transactionRepository,
            pageSize: 500
        )
        let full = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(paged.count == 2500)
        #expect(Set(paged.map(\.id)) == Set(full.map(\.id)))
    }

    @Test("Streaming-CSV entspricht Voll-Export (Zeilen + Sortierung)")
    func streamingCSVMatchesFullExport() async throws {
        let dependencies = try makeDependencies()
        _ = try await seed(dependencies, count: 120)

        let document = try await CSVExportService.makeDocument(dependencies: dependencies)

        // Referenz: Voll-Load + makeCSV (gleiche Spalten/Reihenfolge).
        let full = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let accounts = try await dependencies.accountRepository.accounts()
        let categories = try await dependencies.categoryRepository.categories()
        let tags = try await dependencies.tagRepository.tags()
        let reference = TransactionsCSVExporter(input: .init(
            transactions: full,
            accounts: accounts,
            categories: categories,
            tags: tags
        )).makeCSV(transactions: full)

        // Hinweis: Bei identischen displayDates ordnet der Store stabil nach
        // (effectiveDate, createdAt), der In-Memory-Sort nicht, daher
        // Multimengen-Vergleich plus aufsteigende Datumsfolge im Streaming.
        let streamingLines = document.csv.split(separator: "\r\n").map(String.init)
        let referenceLines = reference.split(separator: "\r\n").map(String.init)
        #expect(streamingLines.count == referenceLines.count)
        #expect(streamingLines.sorted() == referenceLines.sorted())
        let dataLines = streamingLines.dropFirst()
        let dates = dataLines.map { String($0.prefix(10)) }
        #expect(dates == dates.sorted())
    }

    @Test("Backup mit Sparziel überlebt Encode/Decode (V4)")
    func backupPreservesSavingsGoal() async throws {
        let dependencies = try makeDependencies()
        let targetDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 12, day: 31))!
        try await dependencies.budgetRepository.upsert([
            Budget(name: "Urlaub", amount: 300, rolloverPolicy: .accumulate, targetAmount: 1200, targetDate: targetDate)
        ])
        let backup = try await BackupService.makeBackup(dependencies: dependencies)
        #expect(backup.formatVersion == FinanceTrackerBackup.formatVersion)
        #expect(backup.budgets.first?.targetAmount == 1200)
        let roundtrip = try BackupService.decode(BackupService.encode(backup))
        #expect(roundtrip.budgets.first?.targetAmount == 1200)
        #expect(roundtrip.budgets.first?.targetDate == targetDate)
    }
}
