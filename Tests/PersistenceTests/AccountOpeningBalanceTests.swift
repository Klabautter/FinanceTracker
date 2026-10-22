import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@Suite("Konto-Anfangsbestand (Persistenz)")
struct AccountOpeningBalanceTests {
    @Test("Anfangsbestand und Stichtag überleben den Roundtrip; Update entfernt sie wieder")
    func roundTrip() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var account = Account(name: "Geldbeutel", type: .cash, currency: .eur, source: .manual, openingBalance: Decimal(string: "120.50"), openingBalanceDate: date)
        try await dependencies.accountRepository.upsert([account])

        let loaded = try #require(try await dependencies.accountRepository.account(id: account.id))
        #expect(loaded.openingBalance == Decimal(string: "120.50"))
        #expect(loaded.openingBalanceDate == date)
        #expect(loaded.type == .cash)

        account.openingBalance = nil
        account.openingBalanceDate = nil
        try await dependencies.accountRepository.upsert([account])
        let cleared = try #require(try await dependencies.accountRepository.account(id: account.id))
        #expect(cleared.openingBalance == nil)
        #expect(cleared.openingBalanceDate == nil)
        // Sidecar-Zeile ist weg, kein verwaister Eintrag.
        let context = ModelContext(store.container)
        #expect(try context.fetch(FetchDescriptor<SDAccountOpeningBalanceEntity>()).isEmpty)
    }

    @Test("V13 führt die Sidecar-Tabelle, V12 nicht")
    func schemaContainsSidecar() {
        let v13 = FinanceTrackerSchemaV13.models.map { String(describing: $0) }
        let v12 = FinanceTrackerSchemaV12.models.map { String(describing: $0) }
        #expect(v13.contains("SDAccountOpeningBalanceEntity"))
        #expect(!v12.contains("SDAccountOpeningBalanceEntity"))
        #expect(v13.count == v12.count + 1)
    }

    @Test("Korrupter Anfangsbestand wirft statt 0")
    func corruptOpeningBalanceThrows() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Bargeld", type: .cash, currency: .eur, source: .manual, openingBalance: 10)
        try await dependencies.accountRepository.upsert([account])

        let context = ModelContext(store.container)
        let rows = try context.fetch(FetchDescriptor<SDAccountOpeningBalanceEntity>())
        #expect(rows.count == 1)
        rows[0].amountValue = "zehn"
        try context.save()

        await #expect(throws: PersistenceDecodingError.self) {
            _ = try await dependencies.accountRepository.accounts()
        }
    }

    @Test("Kontenliste rechnet den Stand ab Stichtag, ohne Anfangsbestand bleibt er leer")
    @MainActor
    func accountsModelBalance() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let calendar = Calendar.current
        let stichtag = calendar.startOfDay(for: Date())
        let cash = Account(name: "Geldbeutel", type: .cash, currency: .eur, source: .manual, openingBalance: 100, openingBalanceDate: stichtag)
        let giro = Account(name: "Giro", type: .checking, currency: .eur, source: .csvImport)
        try await dependencies.accountRepository.upsert([cash, giro])
        try await dependencies.transactionRepository.upsert([
            Transaction(accountID: cash.id, source: .manual, amount: Money(amount: -30, currency: .eur), bookedAt: calendar.date(byAdding: .day, value: -3, to: stichtag)!),
            Transaction(accountID: cash.id, source: .manual, amount: Money(amount: -10, currency: .eur), bookedAt: stichtag.addingTimeInterval(3_600)),
            Transaction(accountID: cash.id, source: .manual, amount: Money(amount: 5, currency: .eur), bookedAt: calendar.date(byAdding: .day, value: 1, to: stichtag)!),
            Transaction(accountID: giro.id, source: .genericCSV, amount: Money(amount: -42, currency: .eur), bookedAt: stichtag)
        ])

        let model = AccountsModel(dependencies: dependencies)
        await model.load()
        let cashSummary = try #require(model.accounts.first { $0.id == cash.id })
        #expect(cashSummary.balance?.amount == 95)
        #expect(cashSummary.netMovement.amount == -35)
        let giroSummary = try #require(model.accounts.first { $0.id == giro.id })
        #expect(giroSummary.balance == nil)
        #expect(giroSummary.netMovement.amount == -42)
    }
}
