import Foundation
import Testing

@testable import FinanceTracker

/// Neu-Autorisierung bei Enable Banking: neue Sitzung, neue Konto-uid
/// dieselben Buchungen dürfen nicht doppelt erscheinen.
@MainActor
@Suite("Enable Banking: Buchungs-IDs über Neu-Autorisierungen")
struct EnableBankingReauthDuplicateTests {
    private let uidA = "84248c66-4724-41c8-8196-0d4179e4b6e1"
    private let uidB = "a43c8bc2-7f06-4ee5-bd98-ed8c0a8dd823"

    @Test("Sitzungsgebundene ID wird zur stabilen ID")
    func stableID() {
        #expect(EnableBankingExternalIDMigration.stableID(for: "eb-\(uidA)-2026-08-31.0") == "eb-2026-08-31.0")
        #expect(EnableBankingExternalIDMigration.stableID(for: "eb-2026-08-31.0") == nil)
        #expect(EnableBankingExternalIDMigration.stableID(for: "eb-acc-1-5") == nil)
    }

    @Test("Doppelte aus zwei Sitzungen werden zusammengeführt: Nutzerdaten bleiben, Absender kommt neu")
    func mergesDuplicates() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([account])
        let day = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 8, day: 31)))
        let old = Transaction(
            accountID: account.id, source: .openBanking, externalID: "eb-\(uidA)-2026-08-31.0",
            kind: .income, amount: Money(amount: 1034, currency: .eur), bookedAt: day,
            rawDescription: "Foerd.-Nr", rawMerchantName: "Max Alexander Mustermann",
            categoryID: Category.income.id, createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let new = Transaction(
            accountID: account.id, source: .openBanking, externalID: "eb-\(uidB)-2026-08-31.0",
            kind: .income, amount: Money(amount: 1034, currency: .eur), bookedAt: day,
            rawDescription: "Foerd.-Nr", rawMerchantName: "Landeshauptstadt Muenchen",
            merchantDisplayName: "Landeshauptstadt Muenchen", createdAt: Date(timeIntervalSince1970: 2_000)
        )
        // Andere Buchung desselben Tages mit anderem Index bleibt eigenständig.
        let other = Transaction(
            accountID: account.id, source: .openBanking, externalID: "eb-\(uidA)-2026-08-31.1",
            kind: .purchase, amount: Money(amount: -20, currency: .eur), bookedAt: day,
            rawMerchantName: "REWE", createdAt: Date(timeIntervalSince1970: 1_000)
        )
        try await dependencies.transactionRepository.upsert([old, new, other])

        let migration = EnableBankingExternalIDMigration(transactionRepository: dependencies.transactionRepository)
        let outcome = try await migration.run()

        #expect(outcome.merged == 1)
        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.count == 2)
        let kept = try #require(stored.first { $0.id == old.id })
        #expect(kept.externalID == "eb-2026-08-31.0")
        #expect(kept.rawMerchantName == "Landeshauptstadt Muenchen")
        #expect(kept.categoryID == Category.income.id)
        #expect(stored.first { $0.id == other.id }?.externalID == "eb-2026-08-31.1")
        // Zweiter Lauf ändert nichts.
        #expect(try await migration.run() == .init())
    }

    @Test("Gleiche Referenz, aber anderer Betrag: nicht verschmelzen")
    func keepsDifferentBookings() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([account])
        let day = Date()
        let first = Transaction(accountID: account.id, source: .openBanking, externalID: "eb-\(uidA)-x.0",
                                amount: Money(amount: -10, currency: .eur), bookedAt: day,
                                createdAt: Date(timeIntervalSince1970: 1))
        let second = Transaction(accountID: account.id, source: .openBanking, externalID: "eb-\(uidB)-x.0",
                                 amount: Money(amount: -99, currency: .eur), bookedAt: day,
                                 createdAt: Date(timeIntervalSince1970: 2))
        try await dependencies.transactionRepository.upsert([first, second])

        let outcome = try await EnableBankingExternalIDMigration(transactionRepository: dependencies.transactionRepository).run()

        #expect(outcome.merged == 0)
        #expect(try await dependencies.transactionRepository.transactions(matching: TransactionQuery()).count == 2)
    }
}
