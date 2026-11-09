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

    @Test("Kontodetail zeigt denselben Stand wie die Kontenliste: gemeldeter Stand vor Anfangsbestand")
    func accountDetailUsesReportedBalance() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let reportedAt = Date(timeIntervalSince1970: 1_780_000_000)
        // Bankkonto mit gemeldetem Stand und zusätzlich einem (älteren)
        // Anfangsbestand; ein zweites nur mit gemeldetem Stand.
        let both = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking,
            openingBalance: 500, openingBalanceDate: reportedAt.addingTimeInterval(-30 * 86_400))
        let reportedOnly = Account(name: "Tagesgeld", type: .savings, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([both, reportedOnly])
        for account in [both, reportedOnly] {
            try await dependencies.accountRepository.saveReportedBalance(
                ReportedBalance(amount: Money(amount: 1000, currency: .eur), asOf: reportedAt, source: .bank),
                accountID: account.id
            )
        }
        func booking(_ account: Account, _ amount: Decimal, offsetDays: Double) -> Transaction {
            Transaction(accountID: account.id, source: .openBanking, kind: .purchase,
                amount: Money(amount: amount, currency: .eur),
                bookedAt: reportedAt.addingTimeInterval(offsetDays * 86_400))
        }
        try await dependencies.transactionRepository.upsert([
            booking(both, -70, offsetDays: -10),      // steckt im gemeldeten Stand
            booking(both, -40, offsetDays: 1),        // danach gebucht
            booking(reportedOnly, 25, offsetDays: 2)
        ])

        let list = AccountsModel(dependencies: dependencies)
        await list.load()

        for account in [both, reportedOnly] {
            let detail = AccountDetailModel(account: account, dependencies: dependencies)
            await detail.load()
            let listed = try #require(list.accounts.first { $0.id == account.id })
            #expect(detail.errorMessage == nil)
            #expect(detail.balance == listed.balance?.amount)
        }
        let bothDetail = AccountDetailModel(account: both, dependencies: dependencies)
        await bothDetail.load()
        #expect(bothDetail.balance == 960)
    }

    @Test("Stand festlegen: der genannte Stand erscheint in der Liste, Buchungen des Tages eingerechnet")
    func setBalanceShowsEnteredBalance() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let calendar = Calendar.current
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 15))!
        let cash = Account(name: "Geldbeutel", type: .cash, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([cash])
        func booking(_ amount: Decimal, hoursAgo: Double) -> Transaction {
            Transaction(accountID: cash.id, source: .manual, kind: .purchase,
                amount: Money(amount: amount, currency: .eur),
                bookedAt: today.addingTimeInterval(-hoursAgo * 3600))
        }
        try await dependencies.transactionRepository.upsert([
            booking(-12, hoursAgo: 3),      // heute
            booking(-8, hoursAgo: 6),       // heute
            booking(-50, hoursAgo: 40)      // vorgestern, steckt im Stand
        ])
        let model = AccountsModel(dependencies: dependencies)
        await model.load()
        #expect(model.accounts.first?.balance == nil)

        // Im Geldbeutel sind heute Abend 80 €.
        await model.setBalance(80, for: cash, on: today)

        let summary = try #require(model.accounts.first)
        #expect(summary.balance?.amount == 80)
        #expect(summary.balanceBasis == .openingBalance)
        let stored = try #require(await dependencies.accountRepository.account(id: cash.id))
        #expect(stored.openingBalance == 100)
        #expect(stored.openingBalanceDate == calendar.startOfDay(for: today))

        // Eine spätere Buchung verändert den Stand weiter.
        try await dependencies.transactionRepository.upsert([
            Transaction(accountID: cash.id, source: .manual, kind: .purchase,
                amount: Money(amount: -5, currency: .eur), bookedAt: today.addingTimeInterval(86_400))
        ])
        await model.load()
        #expect(model.accounts.first?.balance?.amount == 75)
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
