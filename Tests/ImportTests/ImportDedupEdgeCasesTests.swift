import Foundation
import Testing

@testable import FinanceTracker

/// Dedup/Import-Edge-Cases.
///
/// Fixiert das erwartete Verhalten pro Overlap-Fall:
/// a) gleiche CSV 2x → 2. Mal 100% Duplikate, 0 Inserts, FileHash-Warnung.
/// b) Jan drin, dann Dez+Jan+Feb → nur Dez+Feb neu, Jan Duplicates.
/// c) gleiche Zeilen, anderer Account → KEIN Duplikat (konto-scharf).
/// d) pending X → booked X+2 → updatedCount=1 (Reconciliation, kein Insert).
/// e) booked-Datum >7 Tage → neuer Insert (Reconciler-Limit fixiert).
/// Cross-Source: Ein Bankabruf übernimmt eine schon per Datei importierte
/// Buchung (ein Eintrag, Nutzerdaten bleiben); ein Datei-Import überspringt
/// sie und zählt sie (`crossSourceDuplicates`).
///
/// Fixture-basiert wo CSV (inline CSV-Fixtures, vgl. ImportPipelineTests).
@Suite("ImportDedupEdgeCases")
struct ImportDedupEdgeCasesTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func pipeline(
        _ dependencies: AppDependencies,
        withBatchRepository: Bool = true
    ) -> ImportPipeline {
        ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: withBatchRepository ? dependencies.importBatchRepository : nil,
            fallbackCurrency: .eur
        )
    }

    private var janCSV: Data {
        Data("""
        Date,Memo,Merchant,Amount,Currency
        2026-01-05,Coffee,COFFEE SHOP,-5.40,EUR
        2026-01-06,Groceries,GROCER MART,-62.15,EUR
        """.utf8)
    }

    private var dezJanFebCSV: Data {
        Data("""
        Date,Memo,Merchant,Amount,Currency
        2025-12-20,Gift,BOOK STORE,-12.00,EUR
        2026-01-05,Coffee,COFFEE SHOP,-5.40,EUR
        2026-01-06,Groceries,GROCER MART,-62.15,EUR
        2026-02-02,Bus,CITY TRANSIT,-2.80,EUR
        """.utf8)
    }

    // MARK: - Fingerprint-Härtung (#2)

    @Test("canonicalAmount normalisiert Trailing-Zeros ohne zu runden")
    func canonicalAmountNormalizesTrailingZeros() {
        func fp(_ amount: Decimal) -> String {
            TransactionFingerprinter.fingerprint(
                source: .genericCSV,
                accountID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
                bookingDate: Date(timeIntervalSince1970: 1_750_000_000),
                amount: Money(amount: amount, currency: .eur),
                merchantOrDescription: "X"
            )
        }

        // -5.00 == -5.0 == -5 (sicher gleich trotz unterschiedlicher Skala).
        #expect(fp(Decimal(string: "-5.00")!) == fp(Decimal(string: "-5.0")!))
        #expect(fp(Decimal(string: "-5.00")!) == fp(Decimal(-5)))
        #expect(fp(Decimal(string: "10.00")!) == fp(Decimal(10)))
        #expect(fp(Decimal(string: "-43.270")!) == fp(Decimal(string: "-43.27")!))
        // Keine Identitätsrundung: echte Differenzen bleiben verschieden.
        #expect(fp(Decimal(string: "-10.004")!) != fp(Decimal(-10)))
        #expect(TransactionFingerprinter.canonicalAmount(Money(amount: Decimal(string: "-5.00")!, currency: .eur)) == "-5")
        #expect(TransactionFingerprinter.canonicalAmount(Money(amount: Decimal(string: "0.00")!, currency: .eur)) == "0")
    }

    // MARK: - a) Gleiche CSV 2x

    @Test("a) Gleiche CSV 2x → 2. Mal 100% Duplikate, 0 Inserts, FileHash-Warnung")
    func sameFileTwiceIsFullyDuplicateWithReplayWarning() async throws {
        let dependencies = try makeDependencies()
        let pipe = pipeline(dependencies)
        let accountID = UUID()
        let file = ImportFile(fileName: "jan.csv", data: janCSV)

        let firstPrepared = try await pipe.prepare(file, into: accountID)
        #expect(firstPrepared.isExactFileReplay == false)
        #expect(firstPrepared.transactions.count == 2)
        #expect(firstPrepared.duplicateCount == 0)
        _ = try await pipe.commit(firstPrepared)
        #expect(try await dependencies.transactionRepository.count() == 2)

        let secondPrepared = try await pipe.prepare(file, into: accountID)
        #expect(secondPrepared.isExactFileReplay == true)
        #expect(secondPrepared.fileReplayNotice?.contains("bereits importiert") == true)
        #expect(secondPrepared.transactions.isEmpty)
        #expect(secondPrepared.duplicateCount == 2)
        #expect(secondPrepared.failedCount == 0)
        // Kein stilles Verwerfen (#18): Duplikate sind gezählt, Preview bleibt konsistent (#5).
        #expect(secondPrepared.importResultPreview.duplicateCount == 2)
        #expect(secondPrepared.importResultPreview.summaryMessage.contains("Duplikate übersprungen: 2"))
        #expect(secondPrepared.importResultPreview.isExactFileReplay == true)

        let secondResult = try await pipe.run(file, into: accountID)
        #expect(secondResult.importedCount == 0)
        #expect(secondResult.duplicateCount == 2)
        #expect(secondResult.isExactFileReplay == true)
        #expect(try await dependencies.transactionRepository.count() == 2)
    }

    @Test("a) Ohne Batch-Repository kein Replay-Hinweis, aber row-level Dedup bleibt")
    func sameFileTwiceWithoutBatchRepositoryStillDedups() async throws {
        let dependencies = try makeDependencies()
        let pipe = pipeline(dependencies, withBatchRepository: false)
        let accountID = UUID()
        let file = ImportFile(fileName: "jan.csv", data: janCSV)

        _ = try await pipe.run(file, into: accountID)
        let secondPrepared = try await pipe.prepare(file, into: accountID)
        #expect(secondPrepared.isExactFileReplay == false)
        #expect(secondPrepared.duplicateCount == 2)
        #expect(secondPrepared.transactions.isEmpty)
    }

    // MARK: - b) Überlappende Monate

    @Test("b) Jan drin, dann Dez+Jan+Feb → nur Dez+Feb neu, Jan Duplicates")
    func overlappingMonthsOnlyImportNewRows() async throws {
        let dependencies = try makeDependencies()
        let pipe = pipeline(dependencies)
        let accountID = UUID()

        let first = try await pipe.run(ImportFile(fileName: "jan.csv", data: janCSV), into: accountID)
        #expect(first.importedCount == 2)
        #expect(first.duplicateCount == 0)

        let prepared = try await pipe.prepare(ImportFile(fileName: "dez-jan-feb.csv", data: dezJanFebCSV), into: accountID)
        // Unterschiedlicher Datei-Hash → KEIN exakter Replay, nur row-level Dedup.
        #expect(prepared.isExactFileReplay == false)
        #expect(prepared.transactions.count == 2)
        #expect(prepared.duplicateCount == 2)
        #expect(prepared.failedCount == 0)

        let result = try await pipe.commit(prepared)
        #expect(result.importedCount == 2)
        #expect(result.duplicateCount == 2)
        #expect(try await dependencies.transactionRepository.count() == 4)
    }

    // MARK: - c) Gleicher Inhalt, anderer Account

    @Test("c) Gleiche Zeilen in anderem Account sind KEINE Duplikate")
    func sameRowsInDifferentAccountAreNotDuplicates() async throws {
        let dependencies = try makeDependencies()
        let pipe = pipeline(dependencies)
        let accountA = UUID()
        let accountB = UUID()
        let file = ImportFile(fileName: "jan.csv", data: janCSV)

        let first = try await pipe.run(file, into: accountA)
        #expect(first.importedCount == 2)

        let secondPrepared = try await pipe.prepare(file, into: accountB)
        #expect(secondPrepared.duplicateCount == 0)
        #expect(secondPrepared.transactions.count == 2)
        #expect(secondPrepared.isExactFileReplay == true, "Datei-Hash ist konto-übergreifend gleich: Warnung bleibt, Dedup nicht")
        _ = try await pipe.commit(secondPrepared)
        #expect(try await dependencies.transactionRepository.count() == 4)

        // UI-Hinweis-Text ist vorbereitet (konto-scharfer Fingerprint, #20).
        #expect(!ImportDedupNotices.differentAccountHint.isEmpty)
        #expect(ImportDedupNotices.differentAccountHint.contains("Konto"))
    }

    // MARK: - d) + e) Pending → Booked

    private func bookedDate(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    @Test("d) pending X → booked X+2 → updatedCount=1, kein Insert")
    func pendingToBookedWithinToleranceReconciles() async throws {
        let dependencies = try makeDependencies()
        let pipe = ImportPipeline(
            providers: [],
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )
        let accountID = UUID()
        let pendingAt = bookedDate("2026-08-23T09:10:38Z")
        let bookedAt = bookedDate("2026-08-25T12:00:00Z")

        _ = try await pipe.commitParsedTransactions(
            [ImportedTransaction(
                externalID: "PENDING-BOOKED-1",
                status: .pending,
                kind: .purchase,
                amount: Money(amount: Decimal(string: "-18.30")!, currency: .eur),
                authorizedAt: pendingAt,
                rawDescription: "MCDONALDS 155",
                rawMerchantName: "MCDONALDS 155"
            )],
            source: .genericCSV,
            providerIdentifier: "generic_csv",
            into: accountID
        )
        #expect(try await dependencies.transactionRepository.count() == 1)

        let result = try await pipe.commitParsedTransactions(
            [ImportedTransaction(
                externalID: "PENDING-BOOKED-1",
                status: .booked,
                kind: .purchase,
                amount: Money(amount: Decimal(string: "-18.30")!, currency: .eur),
                bookedAt: bookedAt,
                rawDescription: "MCDONALDS 155",
                rawMerchantName: "MCDONALDS 155"
            )],
            source: .genericCSV,
            providerIdentifier: "generic_csv",
            into: accountID
        )
        #expect(result.updatedCount == 1)
        #expect(result.importedCount == 0)
        #expect(try await dependencies.transactionRepository.count() == 1)
        let stored = try #require(await dependencies.transactionRepository.transactions(matching: TransactionQuery()).first)
        #expect(stored.status == .booked)
    }

    @Test("e) booked-Datum >7 Tage verschoben → neuer Insert (Reconciler-Limit)")
    func bookedBeyondSevenDaysIsNewInsert() async throws {
        let dependencies = try makeDependencies()
        let pipe = ImportPipeline(
            providers: [],
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )
        let accountID = UUID()
        let pendingAt = bookedDate("2026-08-10T09:00:00Z")
        let bookedLate = bookedDate("2026-08-20T09:00:00Z") // +10 Tage > 7-Tage-Limit

        _ = try await pipe.commitParsedTransactions(
            [ImportedTransaction(
                status: .pending,
                kind: .purchase,
                amount: Money(amount: Decimal(string: "-18.30")!, currency: .eur),
                authorizedAt: pendingAt,
                rawDescription: "MCDONALDS 155",
                rawMerchantName: "MCDONALDS 155"
            )],
            source: .genericCSV,
            providerIdentifier: "generic_csv",
            into: accountID
        )

        // Dokumentiert: PendingBookedReconciler.defaultDateTolerance = 7 Tage,
        // amountTolerance = 0.01. Außerhalb → kein Reconcile, neuer Insert.
        #expect(PendingBookedReconciler.defaultDateTolerance == 7 * 24 * 3600)
        #expect(PendingBookedReconciler.amountTolerance == Decimal(string: "0.01")!)

        let result = try await pipe.commitParsedTransactions(
            [ImportedTransaction(
                status: .booked,
                kind: .purchase,
                amount: Money(amount: Decimal(string: "-18.30")!, currency: .eur),
                bookedAt: bookedLate,
                rawDescription: "MCDONALDS 155",
                rawMerchantName: "MCDONALDS 155"
            )],
            source: .genericCSV,
            providerIdentifier: "generic_csv",
            into: accountID
        )
        #expect(result.updatedCount == 0)
        #expect(result.importedCount == 1)
        #expect(try await dependencies.transactionRepository.count() == 2)
    }

    // MARK: - Cross-Source (CSV vs. openBanking)

    @Test("Bankabruf übernimmt die schon per Datei importierte Buchung, Nutzerdaten bleiben")
    func bankSyncAdoptsFileTransaction() async throws {
        let dependencies = try makeDependencies()
        let csvPipe = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            importBatchRepository: dependencies.importBatchRepository,
            fallbackCurrency: .eur
        )
        let accountID = UUID()
        let csv = Data("""
        Date,Memo,Merchant,Amount,Currency
        2026-08-05,Coffee,COFFEE SHOP,-5.40,EUR
        """.utf8)

        let first = try await csvPipe.run(ImportFile(fileName: "csv.csv", data: csv), into: accountID)
        #expect(first.importedCount == 1)
        var fileTransaction = try #require(try await dependencies.transactionRepository.transactions(matching: TransactionQuery()).first)
        fileTransaction.categoryID = Category.restaurants.id
        fileTransaction.note = "Mit Anna"
        try await dependencies.transactionRepository.upsert([fileTransaction])

        // Dieselbe Buchung kommt einen Tag später per Bankabruf, mit Kennung.
        let syncPipe = ImportPipeline(
            providers: [],
            transactionRepository: dependencies.transactionRepository,
            importBatchRepository: dependencies.importBatchRepository,
            fallbackCurrency: .eur
        )
        let bankRow = ImportedTransaction(
            externalID: "bank-1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: Decimal(string: "-5.40")!, currency: .eur),
            bookedAt: bookedDate("2026-08-06T12:00:00Z"),
            rawDescription: "COFFEE SHOP 4711",
            rawMerchantName: "COFFEE SHOP 4711"
        )
        let sync = try await syncPipe.commitParsedTransactions(
            [bankRow], source: .openBanking, providerIdentifier: "openbanking", into: accountID
        )

        #expect(sync.importedCount == 0)
        #expect(sync.updatedCount == 1)
        let all = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(all.count == 1)
        let adopted = try #require(all.first)
        #expect(adopted.id == fileTransaction.id)
        #expect(adopted.source == .openBanking)
        #expect(adopted.externalID == "bank-1")
        #expect(adopted.categoryID == Category.restaurants.id)
        #expect(adopted.note == "Mit Anna")

        // Der nächste Abruf erkennt sie an der Bank-Kennung.
        let secondSync = try await syncPipe.commitParsedTransactions(
            [bankRow], source: .openBanking, providerIdentifier: "openbanking", into: accountID
        )
        #expect(secondSync.importedCount == 0)
        #expect(try await dependencies.transactionRepository.count() == 1)
    }

    @Test("Dieselbe Buchung aus anderer Quelle wird übersprungen und gezählt")
    func crossSourceHintAppearsInPreview() async throws {
        let dependencies = try makeDependencies()
        let accountID = UUID()

        // Bestand aus anderer Quelle direkt anlegen (openBanking).
        let bookedAt = bookedDate("2026-08-05T12:00:00Z")
        try await dependencies.transactionRepository.upsert([
            Transaction(
                accountID: accountID,
                source: .openBanking,
                sourceFingerprint: TransactionFingerprinter.fingerprint(
                    source: .openBanking,
                    accountID: accountID,
                    bookingDate: bookedAt,
                    amount: Money(amount: Decimal(string: "-5.40")!, currency: .eur),
                    merchantOrDescription: "COFFEE SHOP"
                ),
                status: .booked,
                kind: .purchase,
                amount: Money(amount: Decimal(string: "-5.40")!, currency: .eur),
                bookedAt: bookedAt,
                rawDescription: "COFFEE SHOP",
                rawMerchantName: "COFFEE SHOP"
            )
        ])

        // CSV-Import derselben realen Buchung (andere Quelle).
        let csvPipe = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            importBatchRepository: dependencies.importBatchRepository,
            fallbackCurrency: .eur
        )
        let csv = Data("""
        Date,Memo,Merchant,Amount,Currency
        2026-08-05,Coffee,COFFEE SHOP,-5.40,EUR
        """.utf8)
        let prepared = try await csvPipe.prepare(ImportFile(fileName: "csv.csv", data: csv), into: accountID)

        // Dieselbe Buchung aus anderer Quelle wird übersprungen, aber gezählt
        // und mit der vorhandenen Quelle benannt (nicht still verworfen).
        #expect(prepared.transactions.isEmpty)
        #expect(prepared.duplicateCount == 0)
        #expect(prepared.failedCount == 0)
        #expect(prepared.crossSourceDuplicates.count == 1)
        #expect(prepared.crossSourceHints.isEmpty)
        #expect(prepared.importResultPreview.crossSourceDuplicateCount == 1)
        #expect(prepared.importResultPreview.summaryMessage.contains("Bereits vorhanden"))
        #expect(prepared.batch?.duplicateCount == 1)

        // „Trotzdem importieren“: Zeile kommt dazu, als Prüfhinweis markiert.
        let forced = try await csvPipe.prepare(
            ImportFile(fileName: "csv.csv", data: csv),
            into: accountID,
            importCrossSourceDuplicates: true
        )
        #expect(forced.transactions.count == 1)
        #expect(forced.crossSourceDuplicates.isEmpty)
        #expect(forced.crossSourceHints.count == 1)
    }

    @Test("PDF und CSV derselben Karte: abweichendes Datum und Händlertext werden erkannt")
    func crossSourceToleratesDateAndTextVariants() async throws {
        let dependencies = try makeDependencies()
        let accountID = UUID()
        let paidAt = bookedDate("2026-08-05T12:00:00Z")
        try await dependencies.transactionRepository.upsert([
            Transaction(
                accountID: accountID,
                source: .genericCSV,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: Decimal(string: "-18.30")!, currency: .eur),
                bookedAt: paidAt,
                rawDescription: "MCDONALDS 155",
                rawMerchantName: "MCDONALDS 155"
            )
        ])

        let etherFiPipe = ImportPipeline(
            providers: [EtherFiCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )
        let csv = Data("""
        timestamp,type,description,status,amount,currency
        2026-08-07 09:10:38 UTC,card_spend,McDonald's Wien,CLEARED,18.3,EUR
        2026-08-07 10:00:00 UTC,card_spend,McDonald's Wien,CLEARED,18.3,EUR
        2026-08-07 11:00:00 UTC,card_spend,BILLA,CLEARED,18.3,EUR
        """.utf8)
        let prepared = try await etherFiPipe.prepare(ImportFile(fileName: "card.csv", data: csv), into: accountID)

        // Eine vorhandene Buchung deckt genau eine neue Zeile ab; der zweite
        // gleiche Einkauf und der andere Händler kommen neu dazu.
        #expect(prepared.crossSourceDuplicates.count == 1)
        #expect(prepared.transactions.count == 2)
    }

    // MARK: - Summary-Konsistenz (#5)

    @Test("summaryMessage und Preview nutzen identisches Duplikat-Label")
    func summaryMessageMatchesPreview() {
        let result = ImportResult(
            providerIdentifier: "generic_csv",
            totalRows: 3,
            importedCount: 1,
            updatedCount: 1,
            duplicateCount: 2,
            failedCount: 1
        )
        #expect(result.summaryMessage.contains("\(ImportResult.duplicateLabel): 2"))
        #expect(result.summaryMessage.contains("Importiert: 1"))
        #expect(result.summaryMessage.contains("Aktualisiert (Pending→Booked): 1"))
        #expect(result.summaryMessage.contains("Fehlgeschlagen: 1"))

        let replayed = ImportResult(
            providerIdentifier: "generic_csv",
            totalRows: 2,
            importedCount: 0,
            updatedCount: 0,
            duplicateCount: 2,
            failedCount: 0,
            isExactFileReplay: true
        )
        #expect(replayed.summaryMessage.contains(ImportDedupNotices.fileAlreadyImported))
    }
}
