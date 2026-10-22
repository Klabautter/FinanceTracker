import Foundation
import Testing

@testable import FinanceTracker

@Suite("ImportPipeline")
struct ImportPipelineTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private var sampleCSV: Data {
        Data("""
        Date,Memo,Merchant,Amount,Currency
        2026-08-05,Coffee,COFFEE SHOP,-5.40,EUR
        2026-08-06,Groceries,GROCER MART,-62.15,EUR
        2026-08-07,Salary,EMPLOYER INC,2850.00,EUR
        """.utf8)
    }

    @Test("Erstimport importiert alles, Re-Import erkennt alle als Duplikate")
    func deduplicatesOnSecondRun() async throws {
        let dependencies = try makeDependencies()
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )
        let accountID = UUID()
        let file = ImportFile(fileName: "export.csv", data: sampleCSV)

        let firstRun = try await pipeline.run(file, into: accountID)
        #expect(firstRun == ImportResult(
            providerIdentifier: "generic_csv",
            totalRows: 3,
            importedCount: 3,
            updatedCount: 0,
            duplicateCount: 0,
            failedCount: 0
        ))
        #expect(try await dependencies.transactionRepository.count() == 3)

        let secondRun = try await pipeline.run(file, into: accountID)
        #expect(secondRun.importedCount == 0)
        #expect(secondRun.duplicateCount == 3)
        #expect(try await dependencies.transactionRepository.count() == 3)
    }

    @Test("Geänderte Zeile wird neu importiert, unveränderte übersprungen")
    func reimportsChangedRows() async throws {
        let dependencies = try makeDependencies()
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )
        let accountID = UUID()

        _ = try await pipeline.run(ImportFile(fileName: nil, data: sampleCSV), into: accountID)

        let modifiedCSV = Data("""
        Date,Memo,Merchant,Amount,Currency
        2026-08-05,Coffee,COFFEE SHOP,-5.40,EUR
        2026-08-06,Groceries,GROCER MART,-99.99,EUR
        2026-08-08,New Row,NEW MERCHANT,-1.00,EUR
        """.utf8)

        let result = try await pipeline.run(ImportFile(fileName: nil, data: modifiedCSV), into: accountID)

        #expect(result.importedCount == 2)
        #expect(result.duplicateCount == 1)
        #expect(result.failedCount == 0)
    }
    @Test("Kaputte Zeilen werden gezählt statt still verworfen")
    func countsUnparseableRowsAsIssues() async throws {
        let dependencies = try makeDependencies()
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )

        let messyCSV = Data("""
        Date,Memo,Amount
        2026-08-05,Coffee,-5.40
        ,Broken row,not-a-number
        """.utf8)

        let result = try await pipeline.run(ImportFile(fileName: nil, data: messyCSV), into: UUID())

        #expect(result.totalRows == 2)
        #expect(result.importedCount == 1)
        #expect(result.failedCount == 1)
    }

    @Test("Nicht parsebares Datum erzeugt Issue statt Heute-Transaktion")
    func invalidDateBecomesIssue() async throws {
        let dependencies = try makeDependencies()
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )

        let csvWithBadDate = Data("""
        Date,Memo,Amount
        not-a-date,Mystery Row,-12.00
        2026-08-06,Good Row,-1.50
        """.utf8)

        let result = try await pipeline.run(ImportFile(fileName: nil, data: csvWithBadDate), into: UUID())

        #expect(result.totalRows == 2)
        #expect(result.failedCount == 1)
        #expect(result.importedCount == 1)

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.count == 1)
        #expect(stored.first?.effectiveMerchantName != "Mystery Row")
    }

    @Test("prepare liefert Vorschau ohne Persistenz, commit schreibt erst dann")
    func prepareDoesNotPersistUntilCommit() async throws {
        let dependencies = try makeDependencies()
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            categoryRepository: dependencies.categoryRepository,
            fallbackCurrency: .eur
        )
        let accountID = UUID()
        let file = ImportFile(fileName: nil, data: sampleCSV)

        let prepared = try await pipeline.prepare(file, into: accountID)
        #expect(prepared.transactions.count == 3)
        #expect(try await dependencies.transactionRepository.count() == 0)

        let result = try await pipeline.commit(prepared)
        #expect(result.importedCount == 3)
        #expect(try await dependencies.transactionRepository.count() == 3)
    }

    @Test("Import wendet Kategorie-Regeln automatisch an")
    func appliesRulesDuringImport() async throws {
        let dependencies = try makeDependencies()

        let restaurantCategory = Category(name: "Restaurants", systemIconName: "fork.knife")
        try await dependencies.categoryRepository.upsert([restaurantCategory])
        try await dependencies.ruleRepository.upsert([
            CategoryRule(priority: 1, condition: .merchantContains("COFFEE SHOP"), categoryID: restaurantCategory.id)
        ])

        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            categoryRepository: dependencies.categoryRepository,
            fallbackCurrency: .eur
        )

        _ = try await pipeline.run(ImportFile(fileName: nil, data: sampleCSV), into: UUID())

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let coffee = try #require(stored.first { $0.effectiveMerchantName == "COFFEE SHOP" })
        #expect(coffee.categoryID == restaurantCategory.id)

        let others = stored.filter { $0.effectiveMerchantName != "COFFEE SHOP" }
        #expect(others.allSatisfy { $0.categoryID == nil })
    }

    @Test("Import ohne Kategorie-Repository wendet vorhandene Regeln weiterhin an")
    func appliesRulesWithoutCategoryRepository() async throws {
        let dependencies = try makeDependencies()
        let categoryID = UUID()
        try await dependencies.ruleRepository.upsert([
            CategoryRule(
                priority: 1,
                condition: .merchantContains("COFFEE SHOP"),
                categoryID: categoryID
            )
        ])
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            categoryRepository: nil,
            fallbackCurrency: .eur
        )

        _ = try await pipeline.run(
            ImportFile(fileName: nil, data: sampleCSV),
            into: UUID()
        )

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let coffee = try #require(stored.first { $0.effectiveMerchantName == "COFFEE SHOP" })
        #expect(coffee.categoryID == categoryID)
    }

    @Test("Import leitet den Typ aus dem Betragssignal ab statt Unbekannt zu persistieren")
    func infersKindForUnknownImports() async throws {
        let dependencies = try makeDependencies()
        let pipeline = ImportPipeline(
            providers: [],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            fallbackCurrency: .eur
        )

        _ = try await pipeline.commitParsedTransactions(
            [
                ImportedTransaction(
                    externalID: "kind-out-1",
                    status: .booked,
                    kind: .unknown,
                    amount: Money(amount: -42.50, currency: .eur),
                    bookedAt: Date(),
                    rawDescription: "REWE MARKT 1234",
                    rawMerchantName: "REWE MARKT 1234"
                ),
                ImportedTransaction(
                    externalID: "kind-in-1",
                    status: .booked,
                    kind: .unknown,
                    amount: Money(amount: 2850, currency: .eur),
                    bookedAt: Date(),
                    rawDescription: "GEHALT AUGUST",
                    rawMerchantName: "Musterfirma GmbH"
                )
            ],
            source: .openBanking,
            providerIdentifier: "test-bank",
            into: UUID()
        )

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let outgoing = try #require(stored.first { $0.externalID == "kind-out-1" })
        let incoming = try #require(stored.first { $0.externalID == "kind-in-1" })
        #expect(outgoing.kind == .purchase)
        #expect(incoming.kind == .income)
    }

    @Test("CSV und Parsed-Sync nutzen dieselbe Händler- und Regelauflösung")
    func csvAndParsedTransactionsShareCategorizationPath() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        try await dependencies.ruleRepository.upsert([
            CategoryRule(priority: 1, condition: .merchantContains("SPAR"), categoryID: Category.groceries.id)
        ])
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            merchantRepository: dependencies.merchantRepository,
            categoryRepository: dependencies.categoryRepository,
            fallbackCurrency: .eur
        )
        let csv = Data("""
        Date,Merchant,Amount,Currency
        2026-08-05,SPAR MARKT 123,-5.40,EUR
        """.utf8)

        _ = try await pipeline.run(ImportFile(fileName: nil, data: csv), into: UUID())
        _ = try await pipeline.commitParsedTransactions(
            [ImportedTransaction(
                externalID: "sync-spar-1",
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -12, currency: .eur),
                bookedAt: Date(),
                rawDescription: "SPAR DANKT 9988",
                rawMerchantName: "SPAR DANKT 9988"
            )],
            source: .openBanking,
            providerIdentifier: "test-bank",
            into: UUID()
        )

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.merchantDisplayName == "SPAR" })
        #expect(Set(stored.compactMap(\.merchantID)).count == 1)
        #expect(stored.allSatisfy { $0.categoryID == Category.groceries.id })
        let merchant = try #require(await dependencies.merchantRepository.merchants().first { $0.displayName == "SPAR" })
        #expect(merchant.aliases.contains("SPAR MARKT 123"))
        #expect(merchant.aliases.contains("SPAR DANKT 9988"))
    }

    @Test("Import ignoriert Regeln auf Aggregationskategorien")
    func importRejectsParentCategoryTarget() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        try await dependencies.ruleRepository.upsert([
            CategoryRule(priority: 1, condition: .merchantContains("SPAR"), categoryID: Category.food.id)
        ])
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            merchantRepository: dependencies.merchantRepository,
            categoryRepository: dependencies.categoryRepository,
            fallbackCurrency: .eur
        )
        let csv = Data("""
        Date,Merchant,Amount,Currency
        2026-08-05,SPAR MARKT,-5.40,EUR
        """.utf8)

        _ = try await pipeline.run(ImportFile(fileName: nil, data: csv), into: UUID())

        let stored = try #require(await dependencies.transactionRepository.transactions(matching: TransactionQuery()).first)
        #expect(stored.categoryID == nil)
    }

    @Test("Gleiche External-ID auf verschiedenen Konten bleibt erhalten")
    func sameExternalIDAcrossAccountsSurvives() async throws {
        let dependencies = try makeDependencies()
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )

        let csvWithReference = Data("""
        Date,Memo,Merchant,Amount,Currency,Reference
        2026-08-05,Coffee,COFFEE SHOP,-5.40,EUR,TX-1001
        """.utf8)
        let file = ImportFile(fileName: nil, data: csvWithReference)

        _ = try await pipeline.run(file, into: UUID())
        _ = try await pipeline.run(file, into: UUID())

        #expect(try await dependencies.transactionRepository.count() == 2)
    }

    @Test("Externe Provider-ID dedupliziert nur innerhalb derselben Währung")
    func externalIDIsScopedToCurrencyInCSVAndParsedImports() async throws {
        let csvDependencies = try makeDependencies()
        let csvPipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: csvDependencies.transactionRepository,
            fallbackCurrency: .eur
        )
        let csvAccountID = UUID()
        func csv(_ currency: String) -> ImportFile {
            ImportFile(data: Data("""
            Date,Memo,Merchant,Amount,Currency,Reference
            2026-08-05,Purchase,SHOP,-5.40,\(currency),TX-CURRENCY-1
            """.utf8))
        }

        let eurCSV = try await csvPipeline.run(csv("EUR"), into: csvAccountID)
        let usdCSV = try await csvPipeline.run(csv("USD"), into: csvAccountID)
        #expect(eurCSV.importedCount == 1)
        #expect(usdCSV.importedCount == 1)
        #expect(usdCSV.duplicateCount == 0)
        #expect(try await csvDependencies.transactionRepository.count() == 2)

        let replayCSV = try await csvPipeline.run(csv("USD"), into: csvAccountID)
        #expect(replayCSV.importedCount == 0)
        #expect(replayCSV.duplicateCount == 1)
        #expect(try await csvDependencies.transactionRepository.count() == 2)

        let parsedDependencies = try makeDependencies()
        let parsedPipeline = ImportPipeline(
            providers: [],
            transactionRepository: parsedDependencies.transactionRepository,
            fallbackCurrency: .eur
        )
        let parsedAccountID = UUID()
        func parsed(_ currency: CurrencyCode) -> ImportedTransaction {
            ImportedTransaction(
                externalID: "TX-CURRENCY-1",
                status: .booked,
                kind: .purchase,
                amount: Money(amount: Decimal(string: "-5.40")!, currency: currency),
                bookedAt: Date(timeIntervalSince1970: 1_775_000_000),
                rawDescription: "SHOP",
                rawMerchantName: "SHOP"
            )
        }

        let eurParsed = try await parsedPipeline.commitParsedTransactions(
            [parsed(.eur)], source: .openBanking, providerIdentifier: "test-bank", into: parsedAccountID
        )
        let usdParsed = try await parsedPipeline.commitParsedTransactions(
            [parsed(.usd)], source: .openBanking, providerIdentifier: "test-bank", into: parsedAccountID
        )
        #expect(eurParsed.importedCount == 1)
        #expect(usdParsed.importedCount == 1)
        #expect(usdParsed.duplicateCount == 0)
        #expect(try await parsedDependencies.transactionRepository.count() == 2)

        let parsedReplay = try await parsedPipeline.commitParsedTransactions(
            [parsed(.usd)], source: .openBanking, providerIdentifier: "test-bank", into: parsedAccountID
        )
        #expect(parsedReplay.importedCount == 0)
        #expect(parsedReplay.duplicateCount == 1)
        #expect(try await parsedDependencies.transactionRepository.count() == 2)
    }

    @Test("Erkennbare Fremdformat-Datei ohne Provider liefert unsupportedFormat")
    func unsupportedFormatThrows() async throws {
        let dependencies = try makeDependencies()
        let pipeline = ImportPipeline(
            providers: [],
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )

        do {
            _ = try await pipeline.run(
                ImportFile(fileName: "x.csv", data: Data("a,b\n1,2\n".utf8)),
                into: UUID()
            )
            Issue.record("Expected ImportError.unsupportedFormat")
        } catch let error as ImportError {
            #expect(error.userFacingMessage.contains("Kein passender"))
        }
    }
}
