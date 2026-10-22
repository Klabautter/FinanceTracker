import Foundation
import Testing

@testable import FinanceTracker

@Suite("TrustExport")
struct TrustExportTests {
    @Test("CSV: Header, Reihenfolge, Escaping von Komma/Quotes/Newline")
    func csvEscapingAndContent() {
        let account = Account(name: "Giro \"Premium\", Plus", type: .checking, currency: .eur, source: .demo)
        let category = Category(name: "Lebensmittel", systemIconName: "cart")
        let tag = Tag(name: "Urlaub, 2026", colorToken: .blue)

        var txn = Transaction(
            accountID: account.id,
            source: .demo,
            externalID: "csv-1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: Decimal(string: "-42.50")!, currency: .eur),
            bookedAt: Date(timeIntervalSince1970: 1_750_000_000),
            rawDescription: "REWE, \"Sonderangebot\"\nZeile 2",
            rawMerchantName: "REWE, \"Sonderangebot\"",
            merchantDisplayName: "REWE, \"Sonderangebot\"",
            categoryID: category.id,
            note: "Notiz mit, Komma",
            reviewed: true,
            excludedFromAnalytics: false,
            tagIDs: [tag.id]
        )

        let exporter = TransactionsCSVExporter(input: .init(
            transactions: [txn],
            accounts: [account],
            categories: [category],
            tags: [tag]
        ))
        let csv = exporter.makeCSV(transactions: [txn])

        // Header
        #expect(csv.hasPrefix(TransactionsCSVExporter.header.joined(separator: ",")))

        // Zeilenende CRLF (RFC 4180)
        #expect(csv.contains("\r\n"))

        // Escaping: Komma/Quote/Zeilenumbuch im Merchant → gequotetes Feld
        #expect(csv.contains("\"REWE, \"\"Sonderangebot\"\"\nZeile 2\""))

        // Beträge maschinenlesbar (Punkt-Dezimal)
        #expect(csv.contains("-42.5"))

        // Tag-Namen mit Komma werden als Feld korrekt gequotet
        #expect(csv.contains("\"Urlaub, 2026\""))

        // Reviewed/Excluded-Flags
        #expect(csv.contains(",true,false"))
    }

    @Test("Backup: Roundtrip encode/decode erhält alle Daten, Version erzwungen")
    func backupRoundtrip() async throws {
        let dependencies = try await {
            let store = try SwiftDataStore(inMemory: true)
            return AppDependencies.make(container: store.container, baseCurrency: .eur)
        }()

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        let category = Category(name: "Lebensmittel", systemIconName: "cart")
        try await dependencies.categoryRepository.upsert([category])
        let tag = Tag(name: "Dienstlich", colorToken: .green)
        try await dependencies.tagRepository.upsert([tag])

        let txn = Transaction(
            accountID: account.id,
            source: .demo,
            externalID: "bk-1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(string: "19.99")!, currency: .eur),
            bookedAt: Date(),
            rawDescription: "REWE",
            rawMerchantName: "REWE",
            merchantDisplayName: "REWE",
            categoryID: category.id,
            tagIDs: [tag.id]
        )
        try await dependencies.transactionRepository.upsert([txn])
        var annotation = TransactionAnnotation.legacyFallback(for: txn)
        annotation.note = "Backup-Notiz"
        try await dependencies.transactionAnnotationRepository.upsert([annotation])

        try await dependencies.budgetRepository.upsert([
            Budget(name: "Lebensmittel", amount: 400, categoryIDs: [category.id])
        ])

        let backup = try await BackupService.makeBackup(dependencies: dependencies)
        let data = try BackupService.encode(backup)
        let decoded = try BackupService.decode(data)

        #expect(decoded.formatVersion == FinanceTrackerBackup.formatVersion) // WP29: v2
        #expect(decoded.transactions.count == 1)
        #expect(decoded.transactions.first?.externalID == "bk-1")
        #expect(decoded.accounts.first?.name == "Giro")
        #expect(decoded.categories.first?.name == "Lebensmittel")
        #expect(decoded.tags.first?.name == "Dienstlich")
        #expect(decoded.annotations.first?.note == "Backup-Notiz")
        #expect(decoded.budgets.first?.name == "Lebensmittel")

        // Keine Secrets im Backup (Roadmap #151/#186): gezielte Checks
        // statt Substring-Heuristik („colorToken“ enthält „Token“).
        let json = String(data: data, encoding: .utf8) ?? ""
        let lowered = json.lowercased()
        for forbidden in ["accesstoken", "refreshtoken", "secretid", "apikey", "bearer"] {
            #expect(!lowered.contains(forbidden), "Backup darf \(forbidden) nicht enthalten")
        }
    }
}
