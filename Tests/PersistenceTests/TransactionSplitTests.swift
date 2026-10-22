import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@MainActor
@Suite("TransactionSplit")
struct TransactionSplitTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func parentTxn(amount: Decimal) -> Transaction {
        Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .demo,
            externalID: "split-parent",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: Date(),
            rawDescription: "REWE Großkauf",
            rawMerchantName: "REWE",
            merchantDisplayName: "REWE"
        )
    }

    @Test("Invariant: Summe muss Parent-Betrag exakt ergeben")
    func invariant() {
        let parent = parentTxn(amount: -Decimal(string: "85.00")!)
        let cat1 = UUID()

        let valid = TransactionSplitValidator.validate(
            lines: [
                TransactionSplitLine(parentTransactionID: parent.id, amount: Decimal(string: "60.00")!, categoryID: cat1),
                TransactionSplitLine(parentTransactionID: parent.id, amount: Decimal(string: "25.00")!)
            ],
            parent: parent
        )
        #expect(valid == .valid)

        let invalid = TransactionSplitValidator.validate(
            lines: [
                TransactionSplitLine(parentTransactionID: parent.id, amount: Decimal(string: "60.00")!),
                TransactionSplitLine(parentTransactionID: parent.id, amount: Decimal(string: "10.00")!)
            ],
            parent: parent
        )
        guard case .invalid = invalid else {
            Issue.record("Erwartete .invalid")
            return
        }

        let negative = TransactionSplitValidator.validate(
            lines: [TransactionSplitLine(parentTransactionID: parent.id, amount: Decimal(-5))],
            parent: parent
        )
        guard case .invalid = negative else {
            Issue.record("Erwartete .invalid für negativen Betrag")
            return
        }
    }

    @Test("Persistenz-Roundtrip: Speichern, laden, ersetzen")
    func persistenceRoundtrip() async throws {
        let dependencies = try makeDependencies()
        let parent = parentTxn(amount: -Decimal(string: "85.00")!)
        try await dependencies.transactionRepository.upsert([parent])

        let lines = [
            TransactionSplitLine(parentTransactionID: parent.id, amount: Decimal(string: "60.00")!),
            TransactionSplitLine(parentTransactionID: parent.id, amount: Decimal(string: "25.00")!, note: "Drogerie")
        ]
        try await dependencies.transactionSplitRepository.upsert(lines)

        let loaded = try await dependencies.transactionSplitRepository.splitLines(parentTransactionID: parent.id)
        #expect(loaded.count == 2)
        #expect(loaded.reduce(into: Decimal(0)) { $0 += $1.amount } == Decimal(string: "85.00")!)

        // Ersetzen
        try await dependencies.transactionSplitRepository.deleteAll(parentTransactionID: parent.id)
        let replacement = [TransactionSplitLine(parentTransactionID: parent.id, amount: Decimal(string: "85.00")!)]
        try await dependencies.transactionSplitRepository.upsert(replacement)

        let afterReplace = try await dependencies.transactionSplitRepository.splitLines(parentTransactionID: parent.id)
        #expect(afterReplace.count == 1)
        #expect(afterReplace.first?.amount == Decimal(string: "85.00")!)

        // Parent bleibt unverändert
        let parentReloaded = try #require(await dependencies.transactionRepository.transaction(id: parent.id))
        #expect(parentReloaded.amount.amount == Decimal(string: "-85.00")!)
    }

    @Test("V2-Store wird zu V3 migriert, Daten bleiben erhalten, Splits nutzbar")
    func migrationV2ToV3PreservesData() async throws {
        let parentID = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("migration.store")
        defer { try? FileManager.default.removeItem(at: directory) }

        // 1) V2-Store mit Transaktion schreiben
        do {
            let configuration = ModelConfiguration(url: storeURL)
            let oldContainer = try ModelContainer(
                for: Schema(FinanceTrackerSchemaV2.models),
                configurations: [configuration]
            )
            let context = ModelContext(oldContainer)
            context.insert(SDTransactionEntity(
                id: parentID,
                accountID: UUID(),
                sourceRaw: "demo",
                externalID: "mig-1",
                sourceFingerprint: nil,
                statusRaw: "booked",
                kindRaw: "purchase",
                amountValue: "-85.00",
                amountCurrencyRaw: "EUR",
                bookedAt: Date(),
                authorizedAt: nil,
                valueDate: nil,
                effectiveDateValue: Date(),
                rawDescription: "REWE",
                rawMerchantName: "REWE",
                merchantID: nil,
                merchantDisplayName: "REWE",
                categoryID: nil,
                paymentMethodRaw: nil,
                originalCurrencyRaw: nil,
                originalAmountValue: nil,
                cryptoAsset: nil,
                cryptoAmountValue: nil,
                cashbackAmountValue: nil,
                cashbackCurrencyRaw: nil,
                importBatchID: nil,
                searchableText: "rewe",
                note: nil,
                reviewed: false,
                excludedFromAnalytics: false,
                tagIDsJSON: nil,
                createdAt: Date(),
                updatedAt: Date()
            ))
            try context.save()
        }

        // 2) Mit vollem Migrationsplan (V1→V2→V3) öffnen
        let migrated = try SwiftDataStore(url: storeURL)
        let context = ModelContext(migrated.container)

        let txnRows = try context.fetch(FetchDescriptor<SDTransactionEntity>())
        #expect(txnRows.count == 1)
        #expect(txnRows.first?.id == parentID)
        #expect(txnRows.first?.amountValue == "-85.00")

        // 3) Neue V3-Funktion: Split-Line schreiben und lesen
        context.insert(SDTransactionSplitLineEntity(
            id: UUID(),
            parentTransactionID: parentID,
            amountValue: "85.00",
            categoryID: nil,
            note: "Migration-Split",
            createdAt: Date()
        ))
        try context.save()

        let splitRows = try context.fetch(FetchDescriptor<SDTransactionSplitLineEntity>())
        #expect(splitRows.count == 1)
        #expect(splitRows.first?.note == "Migration-Split")
    }

    @Test("Budget-Integration: Split-Lines zählen, Parent nicht (#71)")
    func budgetCountsSplitLines() {
        let calculator = BudgetCalculator()
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        let monthInterval = DateInterval(start: start, end: calendar.date(byAdding: .month, value: 1, to: start)!)

        let catLebensmittel = UUID()
        let catDrogerie = UUID()
        let budgetLebensmittel = Budget(name: "Lebensmittel", amount: 100, categoryIDs: [catLebensmittel])
        let budgetDrogerie = Budget(name: "Drogerie", amount: 50, categoryIDs: [catDrogerie])

        let parent = Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .demo,
            externalID: "split-b",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(string: "85.00")!, currency: .eur),
            bookedAt: Date(),
            rawDescription: "REWE",
            rawMerchantName: "REWE",
            merchantDisplayName: "REWE",
            categoryID: catLebensmittel
        )

        let lines = [
            TransactionSplitLine(parentTransactionID: parent.id, amount: Decimal(string: "60.00")!, categoryID: catLebensmittel),
            TransactionSplitLine(parentTransactionID: parent.id, amount: Decimal(string: "25.00")!, categoryID: catDrogerie)
        ]

        let progresses = calculator.progress(
            budgets: [budgetLebensmittel, budgetDrogerie],
            transactions: [parent],
            categories: [],
            monthInterval: monthInterval,
            calendar: calendar,
            baseCurrency: .eur,
            splitLines: lines
        )

        let lebensmittel = progresses.first { $0.budget.categoryIDs == [catLebensmittel] }
        let drogerie = progresses.first { $0.budget.categoryIDs == [catDrogerie] }

        #expect(lebensmittel?.spent == Decimal(string: "60.00")!)
        #expect(drogerie?.spent == Decimal(string: "25.00")!)
    }
}
