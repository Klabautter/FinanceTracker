import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("Bankkonten heißen nach ihrer Bank")
struct BankAccountNamingTests {
    private func remote(owner: String? = "Max Mustermann", iban: String? = "•••• 4821") -> RemoteBankAccount {
        RemoteBankAccount(id: "acc-1", providerAccountID: "acc-1", ownerName: owner, maskedIBAN: iban, currency: .eur)
    }

    @Test("Bankname, bei mehreren Konten mit IBAN-Ende, sonst Inhaber")
    func defaultNames() {
        #expect(BankSyncService.defaultAccountName(bankName: "DKB", remote: remote(), sharesConnection: false) == "DKB")
        #expect(BankSyncService.defaultAccountName(bankName: "DKB", remote: remote(), sharesConnection: true) == "DKB ••4821")
        #expect(BankSyncService.defaultAccountName(bankName: nil, remote: remote(), sharesConnection: false) == "Max Mustermann")
        #expect(BankSyncService.defaultAccountName(bankName: nil, remote: remote(owner: nil), sharesConnection: false) == "Konto ••cc-1")
    }

    @Test("Automatik-Namen werden ersetzt, eigene Namen bleiben")
    func automaticNames() {
        let auto = Account(name: "Max Mustermann", type: .checking, currency: .eur, source: .openBanking)
        let legacy = Account(name: "Bankkonto ", type: .checking, currency: .eur, source: .openBanking)
        let custom = Account(name: "Girokonto Alltag", type: .checking, currency: .eur, source: .openBanking)
        #expect(BankSyncService.hasAutomaticName(auto, remote: remote()))
        #expect(BankSyncService.hasAutomaticName(legacy, remote: remote()))
        #expect(!BankSyncService.hasAutomaticName(custom, remote: remote()))
    }

    @Test("Abruf benennt ein nach dem Inhaber benanntes Konto nach der Bank um")
    func syncRenames() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let provider = MockBankDataProvider()
        let service = BankSyncService(dependencies: dependencies, provider: provider)
        let connection = try await service.connect(
            institution: BankInstitution(id: "DE|DKB", name: "DKB", bic: nil, transactionTotalDays: nil),
            providerConnectionID: "s",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )
        try await dependencies.accountRepository.upsert([Account(
            connectionID: connection.id, name: "Test User", type: .checking, currency: .eur,
            providerAccountID: "acc-1", source: .openBanking
        )])

        _ = try await service.sync(connection: connection)

        let accounts = try await dependencies.accountRepository.accounts()
        #expect(accounts.map(\.name) == ["DKB"])
    }
}
