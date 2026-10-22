import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("AccountsModel")
struct AccountsModelTests {
    private func makeModel() throws -> AccountsModel {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        return AccountsModel(dependencies: dependencies)
    }

    private func connection(
        status: ConnectionStatus,
        consentExpiresAt: Date? = nil
    ) -> Connection {
        Connection(
            id: UUID(),
            userID: UUID(),
            provider: .enablebanking,
            providerConnectionID: "connection-id",
            institutionID: "institution-id",
            status: status,
            consentExpiresAt: consentExpiresAt,
            lastSuccessfulSyncAt: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    @Test("Aktive Verbindung wird als verbunden angezeigt")
    func activeConnectionStatus() throws {
        let model = try makeModel()
        let active = connection(status: .active, consentExpiresAt: Date().addingTimeInterval(86_400))

        #expect(model.connectionStatusLabel(for: active) == "Verbunden")
        #expect(!model.connectionNeedsReconnect(active))
    }

    @Test("Abgelaufene Zustimmung fordert Wiederverbinden trotz aktivem Status")
    func expiredConsentNeedsReconnect() throws {
        let model = try makeModel()
        let now = Date()
        let expired = connection(status: .active, consentExpiresAt: now.addingTimeInterval(-1))

        #expect(model.connectionStatusLabel(for: expired, now: now) == "Zustimmung abgelaufen")
        #expect(model.connectionNeedsReconnect(expired, now: now))
    }

    @Test("Widerrufene Verbindung fordert Wiederverbinden")
    func revokedConnectionNeedsReconnect() throws {
        let model = try makeModel()
        let revoked = connection(status: .revoked)

        #expect(model.connectionStatusLabel(for: revoked) == "Zugriff widerrufen")
        #expect(model.connectionNeedsReconnect(revoked))
    }

    @Test("Kontodetails trennen Währungen, laden Kategorien und übernehmen Nutzernotizen")
    func accountDetailSemantics() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        let category = Category(name: "Lebensmittel", systemIconName: "basket")
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.categoryRepository.upsert([category])
        let purchase = Transaction(accountID: account.id, source: .manual, kind: .purchase,
            amount: Money(amount: -40, currency: .eur), categoryID: category.id,
            excludedFromAnalytics: true)
        let refund = Transaction(accountID: account.id, source: .manual, kind: .refund,
            amount: Money(amount: 15, currency: .eur))
        let foreign = Transaction(accountID: account.id, source: .manual,
            amount: Money(amount: -100, currency: .usd))
        let reversed = Transaction(accountID: account.id, source: .manual, status: .reversed,
            amount: Money(amount: -200, currency: .eur))
        let otherAccount = Transaction(accountID: UUID(), source: .manual,
            amount: Money(amount: -300, currency: .eur))
        try await dependencies.transactionRepository.upsert([purchase, refund, foreign, reversed, otherAccount])
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(transactionID: purchase.id, note: "Privat")
        ])
        let model = AccountDetailModel(account: account, dependencies: dependencies)
        await model.load()
        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
        #expect(model.netMovement == -25)
        #expect(model.transactionCount == 3)
        #expect(model.foreignCurrencies == [.usd])
        let loaded = try #require(model.transactions.first { $0.id == purchase.id })
        #expect(model.category(for: loaded)?.id == category.id)
        #expect(loaded.note == "Privat")
    }

    @Test("Kontokennung bevorzugt maskierte Bankdaten und unterscheidet gleichnamige Konten")
    func accountIdentifiers() {
        var account = Account(name: "Max Mustermann", type: .checking, currency: .eur,
            maskedIdentifier: "  Max Mustermann  ", source: .openBanking)
        #expect(account.presentationIdentifier == "Referenz " + account.id.uuidString.prefix(8))
        account.maskedIdentifier = "AT••1234"
        #expect(account.presentationIdentifier == "AT••1234")
        account.ibanLast4 = "9876"
        #expect(account.presentationIdentifier == "•••• 9876")
    }

}
