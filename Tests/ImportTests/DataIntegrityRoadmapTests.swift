import Foundation
import Testing

@testable import FinanceTracker

/// Absicherung der Datenfehler aus dem Review vom 16.11.2026: Import-Rückgängig
/// räumt vollständig auf, Backups sind immer wiederherstellbar, mehrdeutige
/// Beträge werden nicht geraten, gebuchte Umsätze bekommen nie das Abrufdatum
/// und manuelle Zahlungspläne werden nicht doppelt gezählt.
@Suite("DataIntegrityRoadmap")
struct DataIntegrityRoadmapTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func makePipeline(_ dependencies: AppDependencies) -> ImportPipeline {
        ImportPipeline(
            providers: dependencies.importProviders,
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            fallbackCurrency: .eur
        )
    }

    private let csv = """
    timestamp,type,description,status,amount,currency
    2026-08-20 12:00:00 UTC,card_spend,SPAR DANKT,CLEARED,33.08,EUR
    """

    // MARK: - Import-Rückgängig

    @Test("Rückgängig entfernt Anmerkung, Split und Beleg-Metadaten; das Backup bleibt gültig")
    func undoRemovesDependentsAndKeepsBackupRestorable() async throws {
        let dependencies = try makeDependencies()
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        _ = try await makePipeline(dependencies).run(ImportFile(fileName: nil, data: Data(csv.utf8)), into: account.id)

        let imported = try #require(await dependencies.transactionRepository.transactions(matching: TransactionQuery()).first)
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(transactionID: imported.id, note: "Geprüft", reviewed: true)
        ])
        try await dependencies.transactionSplitRepository.upsert([
            TransactionSplitLine(parentTransactionID: imported.id, amount: Decimal(string: "33.08")!)
        ])
        try await dependencies.transactionAttachmentRepository.add(
            TransactionAttachment(transactionID: imported.id, fileName: "b.pdf", mimeType: "application/pdf", localRelativePath: "b.pdf")
        )

        let batch = try #require(await dependencies.importBatchRepository.batches().first)
        try await dependencies.importBatchRepository.rollbackImportBatch(id: batch.id)

        #expect(try await dependencies.transactionRepository.transactions(matching: TransactionQuery()).isEmpty)
        #expect(try await dependencies.transactionAnnotationRepository.annotations().isEmpty)
        #expect(try await dependencies.transactionSplitRepository.allSplitLines().isEmpty)
        #expect(try await dependencies.transactionAttachmentRepository.allAttachments().isEmpty)
        // Vorher lehnte die Wiederherstellung dieses Backup ab.
        let backup = try await BackupService.makeBackup(dependencies: dependencies)
        try BackupRestoreService.validate(backup)
    }

    @Test("Reparatur entfernt verwaiste Zeilen früherer Rückgängig-Läufe")
    func purgeRemovesOrphans() async throws {
        let dependencies = try makeDependencies()
        let missingTransaction = UUID()
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(transactionID: missingTransaction, note: "Rest")
        ])
        try await dependencies.transactionSplitRepository.upsert([
            TransactionSplitLine(parentTransactionID: missingTransaction, amount: 5)
        ])

        let removed = try await dependencies.transactionRepository.purgeOrphanedDependents()

        #expect(removed == 2)
        #expect(try await dependencies.transactionAnnotationRepository.annotations().isEmpty)
        #expect(try await dependencies.transactionSplitRepository.allSplitLines().isEmpty)
        #expect(try await dependencies.transactionRepository.purgeOrphanedDependents() == 0)
    }

    @Test("Unlesbarer Vorher-Stand wird nicht als 0 / gebucht / manuell wiederhergestellt")
    func corruptSnapshotThrows() throws {
        let original = Transaction(
            accountID: UUID(), source: .genericCSV, externalID: "x", status: .pending, kind: .purchase,
            amount: Money(amount: -5, currency: .eur), bookedAt: nil,
            rawDescription: "A", rawMerchantName: "A", merchantDisplayName: "A"
        )
        let snapshot = TransactionSnapshot(transaction: original)
        #expect(try snapshot.restoring(id: original.id).status == .pending)

        var corrupt = snapshot
        corrupt.statusRaw = "kaputt"
        #expect(throws: ImportMutationError.self) { try corrupt.restoring(id: original.id) }
        var corruptAmount = snapshot
        corruptAmount.amountValue = "abc"
        #expect(throws: ImportMutationError.self) { try corruptAmount.restoring(id: original.id) }
    }

    // MARK: - Dezimaleingabe

    @Test("Eingabefeld: „1.500“ ist auf Deutsch tausendfünfhundert, „0.99“ bleibt 0,99")
    func decimalInputFollowsLocale() {
        let german = Locale(identifier: "de_DE")
        let english = Locale(identifier: "en_US")
        #expect(DecimalInputField.parse("1.500", locale: german) == 1500)
        #expect(DecimalInputField.parse("1.500,50", locale: german) == Decimal(string: "1500.50"))
        #expect(DecimalInputField.parse("0.99", locale: german) == Decimal(string: "0.99"))
        #expect(DecimalInputField.parse("12,5", locale: german) == Decimal(string: "12.5"))
        #expect(DecimalInputField.parse("1,500", locale: english) == 1500)
        #expect(DecimalInputField.parse("1.500", locale: english) == Decimal(string: "1.5"))
        #expect(DecimalInputField.parse("12-3", locale: german) == nil)
        #expect(DecimalInputField.editText(Decimal(string: "1500.5")!, locale: german) == "1500,5")
    }

    // MARK: - CSV ohne erkennbaren Dezimaltrenner

    private let ambiguousCSV = """
    Datum;Beschreibung;Betrag
    01.10.2026;Miete;-1.000
    02.10.2026;Gehalt;2.500
    """

    @Test("CSV mit nur „1.000“-Beträgen fragt nach statt still zu raten")
    func ambiguousCSVNeedsAnswer() async throws {
        let file = ImportFile(fileName: "a.csv", data: Data(ambiguousCSV.utf8))
        let unanswered = try await GenericCSVProvider().parse(file)
        #expect(unanswered.assumedDecimalSeparator != nil)

        let thousands = try await GenericCSVProvider(decimalSeparatorChoice: ",").parse(file)
        #expect(thousands.assumedDecimalSeparator == nil)
        #expect(thousands.transactions.map(\.amount.amount).sorted() == [-1000, 2500])

        let ones = try await GenericCSVProvider(decimalSeparatorChoice: ".").parse(file)
        #expect(ones.transactions.map(\.amount.amount).sorted() == [-1, Decimal(string: "2.5")!])
    }

    @Test("CSV mit erkennbarem Trenner fragt nicht nach")
    func unambiguousCSVDoesNotAsk() async throws {
        let text = ambiguousCSV + "\n03.10.2026;Bäcker;-3,20"
        let result = try await GenericCSVProvider().parse(ImportFile(fileName: "b.csv", data: Data(text.utf8)))
        #expect(result.assumedDecimalSeparator == nil)
        #expect(result.transactions.map(\.amount.amount).contains(-1000))
    }

    // MARK: - Bankabruf ohne Buchungsdatum

    private func decode(_ json: String) throws -> EnableBankingTransaction {
        try JSONDecoder().decode(EnableBankingTransaction.self, from: Data(json.utf8))
    }

    @Test("Gebuchter Umsatz ohne jedes Datum wird abgelehnt, mit Wertstellung angenommen")
    func bookedWithoutDate() throws {
        let noDate = try decode(#"{"entry_reference":"1","transaction_amount":{"amount":"5.00","currency":"EUR"},"credit_debit_indicator":"DBIT","status":"BOOK"}"#)
        #expect(EnableBankingBankDataProvider.rejectionReason(noDate) == "booking_date (fehlt)")

        let valueOnly = try decode(#"{"entry_reference":"2","transaction_amount":{"amount":"5.00","currency":"EUR"},"credit_debit_indicator":"DBIT","status":"BOOK","value_date":"2026-10-02"}"#)
        #expect(EnableBankingBankDataProvider.rejectionReason(valueOnly) == nil)

        let unreadable = try decode(#"{"entry_reference":"3","transaction_amount":{"amount":"5.00","currency":"EUR"},"credit_debit_indicator":"DBIT","status":"BOOK","booking_date":"gestern"}"#)
        #expect(EnableBankingBankDataProvider.rejectionReason(unreadable) == "booking_date")
    }

    // MARK: - Manueller Zahlungsplan ohne Händler

    @Test("Manuelles Gehalt ohne Händler wird in der Prognose nicht doppelt gezählt")
    func keylessSalaryCountsOnce() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let period = DateInterval(start: start, end: calendar.date(byAdding: .month, value: 1, to: start)!)
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12))!
        let salary = RecurringCommitment(
            name: "Gehalt", merchantKey: nil, direction: .income, cadence: .monthly,
            amountPolicy: .fixed, expectedAmount: 2850, currency: .eur,
            nextExpectedDate: calendar.date(from: DateComponents(year: 2026, month: 3, day: 28)), status: .active
        )
        let paid = Transaction(
            accountID: UUID(), source: .demo, externalID: "g", status: .booked, kind: .income,
            amount: Money(amount: 2850, currency: .eur),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 9)),
            rawDescription: "ACME GMBH", rawMerchantName: "ACME GMBH", merchantDisplayName: "ACME GMBH"
        )
        let snapshot = ForecastService().forecast(
            period: period, transactions: [paid], budgets: [], budgetProgresses: [],
            commitments: [salary], baseCurrency: .eur, calendar: calendar, now: now
        )
        #expect(snapshot.realizedIncome == 2850)
        #expect(snapshot.expectedIncome == 0)
        #expect(snapshot.availableAmount == 2850)
    }

    @Test("Händlervorschläge: gleiche Richtung, ähnlicher Betrag, häufigste zuerst")
    func merchantSuggestions() {
        let now = Date()
        let account = UUID()
        func txn(_ name: String, _ amount: Decimal, daysAgo: Int) -> Transaction {
            Transaction(
                accountID: account, source: .demo, externalID: UUID().uuidString, status: .booked, kind: .purchase,
                amount: Money(amount: amount, currency: .eur),
                bookedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: now),
                rawDescription: name, rawMerchantName: name, merchantDisplayName: name
            )
        }
        let suggestions = ManualCommitmentMerchantSuggestions.suggest(
            direction: .expense, amount: 985, currency: .eur,
            transactions: [
                txn("Vermieter", -985, daysAgo: 5), txn("Vermieter", -985, daysAgo: 35),
                txn("Bäcker", -3, daysAgo: 2), txn("Arbeitgeber", 985, daysAgo: 3),
                txn("Altmieter", -985, daysAgo: 400)
            ],
            now: now
        )
        #expect(suggestions.map(\.label) == ["Vermieter"])
        #expect(suggestions.first?.count == 2)
    }
}
