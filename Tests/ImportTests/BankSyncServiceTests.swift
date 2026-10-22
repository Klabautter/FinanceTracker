import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("BankSyncService")
struct BankSyncServiceTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private let calendar = Calendar(identifier: .gregorian)

    private func remoteTxn(_ id: String, _ amount: String, day: Int, pending: Bool = false, merchant: String = "REWE MARKT") -> RemoteBankTransaction {
        RemoteBankTransaction(
            externalID: id,
            state: pending ? .pending : .booked,
            amount: Money(amount: Decimal(string: amount)!, currency: .eur),
            bookingDate: pending ? nil : calendar.date(from: DateComponents(year: 2026, month: 8, day: day)),
            valueDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: day)),
            creditorName: amount.hasPrefix("-") ? merchant : nil,
            debtorName: amount.hasPrefix("-") ? nil : "Arbeitgeber",
            remittanceInformation: "\(merchant) Zahlung"
        )
    }

    @Test("Connect legt Bank-Accounts an, Sync importiert über die Pipeline")
    func connectAndSync() async throws {
        let dependencies = try makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [
            remoteTxn("T1", "-43.27", day: 20),
            remoteTxn("T2", "2850.00", day: 30)
        ]
        let service = BankSyncService(dependencies: dependencies, provider: provider)

        let connection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "req-1",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs,
            consentDays: 180
        )

        let accounts = try await dependencies.accountRepository.accounts()
        #expect(accounts.isEmpty)

        let result = try await service.sync(connection: connection)

        #expect(result.accountsSynced == 1)
        #expect(result.importedCount == 2)

        let storedAccounts = try await dependencies.accountRepository.accounts()
        #expect(storedAccounts.count == 1)
        #expect(storedAccounts[0].source == .openBanking)
        #expect(storedAccounts[0].providerAccountID == "acc-1")
        #expect(storedAccounts[0].institutionID == "SANDBOXFINANCE_SFIN000033")

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.source == .openBanking })
        #expect(stored.allSatisfy { $0.importBatchID != nil })

        let batches = try await dependencies.importBatchRepository.batches()
        #expect(batches.count == 1)
        #expect(batches[0].providerIdentifier == ConnectionProvider.gocardless.rawValue)
    }

    @Test("BankSync persistiert kanonische Merchant-Identität, Alias und Kategorie")
    func syncUsesSharedMerchantAndRulePath() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        try await dependencies.ruleRepository.upsert(CategoryRule.defaultCatalog())
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [remoteTxn("S1", "-43.27", day: 20, merchant: "SPAR MARKT 4711")]
        let service = BankSyncService(dependencies: dependencies, provider: provider)
        let connection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "merchant-sync",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )

        _ = try await service.sync(connection: connection)

        let transaction = try #require(await dependencies.transactionRepository.transactions(matching: TransactionQuery()).first)
        let merchantID = try #require(transaction.merchantID)
        let merchant = try #require(await dependencies.merchantRepository.merchant(id: merchantID))
        #expect(transaction.merchantDisplayName == "SPAR")
        #expect(transaction.categoryID == Category.groceries.id)
        #expect(merchant.displayName == "SPAR")
        #expect(merchant.aliases.contains("SPAR MARKT 4711"))
    }

    @Test("BankSync kategorisiert Gehalt nur als positiven Beschreibungs-Treffer")
    func syncUsesSignedDescriptionRule() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        try await dependencies.ruleRepository.upsert(CategoryRule.defaultCatalog())
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [
            remoteTxn("SALARY", "2850.00", day: 30, merchant: "GEHALT AUGUST"),
            remoteTxn("CORRECTION", "-100.00", day: 31, merchant: "GEHALT KORREKTUR")
        ]
        let service = BankSyncService(dependencies: dependencies, provider: provider)
        let connection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "salary-sync",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )

        _ = try await service.sync(connection: connection)

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.first { $0.externalID == "SALARY" }?.categoryID == Category.income.id)
        #expect(stored.first { $0.externalID == "CORRECTION" }?.categoryID == nil)
    }

    @Test("Re-Sync erkennt alles als Duplikat, neue Zeile wird importiert")
    func reSyncDeduplicates() async throws {
        let dependencies = try makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [remoteTxn("T1", "-43.27", day: 20)]
        let service = BankSyncService(dependencies: dependencies, provider: provider)

        let connection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "req-1",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )

        _ = try await service.sync(connection: connection)
        let secondRun = try await service.sync(connection: connection)

        #expect(secondRun.importedCount == 0)
        #expect(secondRun.duplicateCount == 1)

        provider.stubbedTransactions.append(remoteTxn("T9", "-7.77", day: 25))
        let thirdRun = try await service.sync(connection: connection)

        #expect(thirdRun.importedCount == 1)
        #expect(try await dependencies.transactionRepository.count() == 2)
    }

    @Test("Ein Sync pro Konto: Details nur einmal abgefragt (keine Doppel-Requests)")
    func accountDetailsFetchedOncePerSync() async throws {
        let dependencies = try makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [remoteTxn("T1", "-43.27", day: 20)]
        let service = BankSyncService(dependencies: dependencies, provider: provider)

        let connection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "req-1",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )
        let callsBefore = await provider.fetchAccountDataCallCount
        _ = try await service.sync(connection: connection)
        let callsAfter = await provider.fetchAccountDataCallCount

        #expect(callsAfter - callsBefore == 1, "Pro Sync darf der Account-Details-Pfad nur einmal laufen")
    }

    @Test("Pending→Booked zwischen zwei Syncs wird reconciled statt dupliziert")
    func pendingToBookedAcrossSyncs() async throws {
        let dependencies = try makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [remoteTxn("P1", "-18.30", day: 23, pending: true)]
        let service = BankSyncService(dependencies: dependencies, provider: provider)

        let connection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "req-1",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )
        _ = try await service.sync(connection: connection)

        provider.stubbedTransactions = [remoteTxn("B1", "-18.30", day: 24)]
        let second = try await service.sync(connection: connection)

        #expect(second.updatedCount == 1)
        #expect(second.importedCount == 0)

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.count == 1)
        #expect(stored.first?.status == .booked)
    }

    // MARK: - WP-MacUX: Re-Connect-Dedup (keine doppelten Konten)

    private func reconnect(
        _ service: BankSyncService,
        provider: MockBankDataProvider
    ) async throws -> Connection {
        try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "req-\(UUID().uuidString)",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )
    }

    @Test("Re-Connect hängt das bestehende Konto an die neue Verbindung statt zu duplizieren")
    func reconnectRelinksSameProviderAccountID() async throws {
        let dependencies = try makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [remoteTxn("T1", "-43.27", day: 20)]
        let service = BankSyncService(dependencies: dependencies, provider: provider)

        let firstConnection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "req-1",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )
        _ = try await service.sync(connection: firstConnection)

        // Re-Connect: neue Connection-ID, gleiches Provider-Konto.
        let secondConnection = try await reconnect(service, provider: provider)
        #expect(secondConnection.id != firstConnection.id)
        let secondRun = try await service.sync(connection: secondConnection)

        #expect(secondRun.accountsSynced == 1)
        let storedAccounts = try await dependencies.accountRepository.accounts()
        #expect(storedAccounts.count == 1, "Das Konto darf beim Re-Connect nicht dupliziert werden")
        #expect(storedAccounts.first?.connectionID == secondConnection.id)
        #expect(storedAccounts.first?.isActive == true)
    }

    @Test("Session-übergreifende Provider-Account-IDs werden über den IBAN-Fingerprint dedupliziert")
    func reconnectRelinksViaIBANFingerprint() async throws {
        let dependencies = try makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [remoteTxn("T1", "-43.27", day: 20)]
        let service = BankSyncService(dependencies: dependencies, provider: provider)

        let firstConnection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "req-1",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )
        _ = try await service.sync(connection: firstConnection)

        // Neue Session vergibt eine NEUE Provider-Account-ID; die maskierte
        // IBAN („•••• 4821") bleibt gleich.
        provider.stubbedRemoteAccounts = [RemoteBankAccount(
            id: "acc-2",
            providerAccountID: "session-2-acc",
            ownerName: "Test User",
            maskedIBAN: "•••• 4821",
            currency: .eur
        )]
        provider.stubbedLinkedAccountIDs = ["acc-2"]
        let secondConnection = try await reconnect(service, provider: provider)
        _ = try await service.sync(connection: secondConnection)

        let storedAccounts = try await dependencies.accountRepository.accounts()
        #expect(storedAccounts.count == 1, "Gleiche masked IBAN + Währung = gleiches Konto")
        #expect(storedAccounts.first?.connectionID == secondConnection.id)
    }

    @Test("Verschiedene Konten (unterschiedliche masked IBAN) bleiben getrennt")
    func distinctAccountsAreNotMerged() async throws {
        let dependencies = try makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [remoteTxn("T1", "-43.27", day: 20)]
        let service = BankSyncService(dependencies: dependencies, provider: provider)

        let firstConnection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "req-1",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )
        _ = try await service.sync(connection: firstConnection)

        provider.stubbedRemoteAccounts = [RemoteBankAccount(
            id: "acc-2",
            providerAccountID: "acc-2",
            ownerName: "Test User",
            maskedIBAN: "•••• 9999",
            currency: .eur
        )]
        provider.stubbedLinkedAccountIDs = ["acc-2"]
        let secondConnection = try await reconnect(service, provider: provider)
        _ = try await service.sync(connection: secondConnection)

        let storedAccounts = try await dependencies.accountRepository.accounts()
        #expect(storedAccounts.count == 2)
    }

    @Test("Ein angefragter Zeitraum geht als Startdatum an die Bank; das Ergebnis nennt die älteste gelieferte Buchung")
    func historyStartIsRequested() async throws {
        let dependencies = try makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [remoteTxn("T1", "-10.00", day: 20), remoteTxn("T2", "-5.00", day: 3)]
        let service = BankSyncService(dependencies: dependencies, provider: provider)
        let connection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "req-history",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )
        let start = try #require(calendar.date(from: DateComponents(year: 2025, month: 8, day: 1)))

        let result = try await service.sync(connection: connection, historyStart: start)

        #expect(provider.lastRequestedDateFrom == .some(start))
        #expect(result.earliestBookingDate == calendar.date(from: DateComponents(year: 2026, month: 8, day: 3)))
    }

    @Test("Ohne angefragten Zeitraum entscheidet beim ersten Abruf die Bank")
    func firstSyncWithoutHistoryStart() async throws {
        let dependencies = try makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [remoteTxn("T1", "-10.00", day: 20)]
        let service = BankSyncService(dependencies: dependencies, provider: provider)
        let connection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "req-default",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )
        _ = try await service.sync(connection: connection)
        #expect(provider.lastRequestedDateFrom == .some(nil))
    }

    @Test("Neuanmeldung: Das Konto wird über die stabile Kennung wiedererkannt, nicht doppelt angelegt")
    func reauthReusesAccount() async throws {
        let dependencies = try makeDependencies()
        let service = BankSyncService(dependencies: dependencies, provider: MockBankDataProvider())
        let institution = BankInstitution(id: "DE|VR Bank Beispiel", name: "VR Bank Beispiel", bic: nil, transactionTotalDays: nil)

        let first = try await service.connect(institution: institution, providerConnectionID: "s1", linkedAccountIDs: [], providerRaw: .enablebanking)
        let original = try await service.ensureBankAccount(
            remote: RemoteBankAccount(id: "uid-1", providerAccountID: "stable-hash", ownerName: "Erika", maskedIBAN: nil, currency: .eur),
            connection: first,
            fallbackName: "Erika"
        )

        let second = try await service.connect(institution: institution, providerConnectionID: "s2", linkedAccountIDs: [], providerRaw: .enablebanking)
        let again = try await service.ensureBankAccount(
            remote: RemoteBankAccount(id: "uid-2", providerAccountID: "stable-hash", ownerName: "Erika", maskedIBAN: nil, currency: .eur),
            connection: second,
            fallbackName: "Erika"
        )

        #expect(again.id == original.id)
        #expect(again.connectionID == second.id)
        #expect(try await dependencies.accountRepository.accounts().count == 1)
    }

    @Test("Konten mit alter Sitzungs-ID bekommen beim nächsten Abruf die stabile Kennung")
    func migratesSessionIDToStableID() async throws {
        let dependencies = try makeDependencies()
        let service = BankSyncService(dependencies: dependencies, provider: MockBankDataProvider())
        let institution = BankInstitution(id: "DE|VR Bank Beispiel", name: "VR Bank Beispiel", bic: nil, transactionTotalDays: nil)
        let connection = try await service.connect(institution: institution, providerConnectionID: "s1", linkedAccountIDs: [], providerRaw: .enablebanking)

        // Früher gespeichert: Sitzungs-ID als Konto-Kennung.
        let legacy = try await service.ensureBankAccount(
            remote: RemoteBankAccount(id: "uid-1", providerAccountID: "uid-1", ownerName: "Erika", maskedIBAN: nil, currency: .eur),
            connection: connection,
            fallbackName: "Erika"
        )
        let migrated = try await service.ensureBankAccount(
            remote: RemoteBankAccount(id: "uid-1", providerAccountID: "stable-hash", ownerName: "Erika", maskedIBAN: nil, currency: .eur),
            connection: connection,
            fallbackName: "Erika"
        )

        #expect(migrated.id == legacy.id)
        #expect(migrated.providerAccountID == "stable-hash")
        #expect(try await dependencies.accountRepository.accounts().count == 1)
    }
}
