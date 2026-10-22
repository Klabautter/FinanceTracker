import Foundation
import Testing

@testable import FinanceTracker

@Suite("Bargeldabhebung → Geldbeutel")
struct CashWithdrawalTests {
    private func txn(_ amount: String, account: UUID, description: String?, merchant: String? = nil, currency: CurrencyCode = .eur, status: TransactionStatus = .booked) -> Transaction {
        Transaction(
            accountID: account,
            source: .openBanking,
            externalID: UUID().uuidString,
            status: status,
            amount: Money(amount: Decimal(string: amount)!, currency: currency),
            bookedAt: Date(timeIntervalSince1970: 1_790_000_000),
            rawDescription: description,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
    }

    @Test("Erkennung: Geldautomat, Bargeldauszahlung, ATM als Wort; Cashback und Einnahmen nicht")
    func detector() {
        let giro = UUID()
        #expect(CashWithdrawalDetector.isWithdrawal(txn("-100", account: giro, description: "GELDAUTOMAT 1234 WIEN")))
        #expect(CashWithdrawalDetector.isWithdrawal(txn("-50", account: giro, description: "Bargeldauszahlung Sparkasse")))
        #expect(CashWithdrawalDetector.isWithdrawal(txn("-20", account: giro, description: nil, merchant: "ATM Bankomat")))
        #expect(CashWithdrawalDetector.isWithdrawal(txn("-20", account: giro, description: "CASH WITHDRAWAL LONDON")))
        #expect(!CashWithdrawalDetector.isWithdrawal(txn("-20", account: giro, description: "ATMOSPHERE BAR")))
        #expect(!CashWithdrawalDetector.isWithdrawal(txn("-20", account: giro, description: "REWE CASHBACK 5 EUR")))
        #expect(!CashWithdrawalDetector.isWithdrawal(txn("100", account: giro, description: "GELDAUTOMAT EINZAHLUNG")))
        #expect(!CashWithdrawalDetector.isWithdrawal(txn("-100", account: giro, description: "GELDAUTOMAT", status: .cancelled)))
        #expect(!CashWithdrawalDetector.isWithdrawal(txn("-30", account: giro, description: "BILLA DANKT")))
    }

    @Test("Gegenbuchung im Bargeldkonto, Quelle wird Transfer, zweiter Aufruf legt nichts doppelt an")
    func mirrorCreatesCounterpartOnce() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur, preferences: InMemoryAppPreferences())
        let giro = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        let cash = Account(name: "Geldbeutel", type: .cash, currency: .eur, source: .manual, openingBalance: 20)
        try await dependencies.accountRepository.upsert([giro, cash])
        let withdrawal = txn("-100", account: giro.id, description: "GELDAUTOMAT 4711")
        try await dependencies.transactionRepository.upsert([withdrawal])

        let useCase = MirrorCashWithdrawal(dependencies: dependencies)
        let outcome = try await useCase.mirror(withdrawal, into: cash, sourceAccountName: giro.name)
        guard case .created(let counterpart) = outcome else {
            Issue.record("Erwartet .created, war \(outcome)"); return
        }
        #expect(counterpart.accountID == cash.id)
        #expect(counterpart.amount == Money(amount: 100, currency: .eur))
        #expect(counterpart.kind == .transfer)
        #expect(counterpart.source == .manual)
        #expect(counterpart.categoryID == Category.transfers.id)
        #expect(counterpart.merchantDisplayName == "Bargeldabhebung")
        #expect(counterpart.rawDescription?.contains("Giro") == true)

        let annotation = try #require(try await dependencies.transactionAnnotationRepository.annotation(transactionID: withdrawal.id))
        #expect(annotation.manualKindOverride == .transfer)

        #expect(try await useCase.mirror(withdrawal, into: cash, sourceAccountName: giro.name) == .alreadyMirrored)
        var query = TransactionQuery()
        query.accountIDs = [cash.id]
        #expect(try await dependencies.transactionRepository.transactions(matching: query).count == 1)

        // Stand im Bargeldkonto: 20 + 100.
        let model = await MainActor.run { AccountsModel(dependencies: dependencies) }
        await model.load()
        let summary = try #require(await MainActor.run { model.accounts.first { $0.id == cash.id } })
        #expect(summary.balance?.amount == 120)
    }

    @Test("Fremdwährung, Einnahmen und Buchungen des Bargeldkontos selbst werden nicht gespiegelt")
    func mirrorRejectsIneligible() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur, preferences: InMemoryAppPreferences())
        let usdCard = Account(name: "USD-Karte", type: .creditCard, currency: .usd, source: .openBanking)
        let cash = Account(name: "Geldbeutel", type: .cash, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([usdCard, cash])
        let useCase = MirrorCashWithdrawal(dependencies: dependencies)

        #expect(try await useCase.mirror(txn("-40", account: usdCard.id, description: "ATM", currency: .usd), into: cash, sourceAccountName: "x") == .currencyMismatch)
        #expect(try await useCase.mirror(txn("40", account: usdCard.id, description: "ATM"), into: cash, sourceAccountName: "x") == .notEligible)
        #expect(try await useCase.mirror(txn("-40", account: cash.id, description: "ATM"), into: cash, sourceAccountName: "x") == .notEligible)
    }

    @Test("Automatik: nur mit eingestelltem, aktivem Bargeldkonto; erkennt nur Abhebungen")
    func automationRespectsPreference() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let preferences = InMemoryAppPreferences()
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur, preferences: preferences)
        let giro = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        let cash = Account(name: "Geldbeutel", type: .cash, currency: .eur, source: .manual, openingBalance: 0)
        try await dependencies.accountRepository.upsert([giro, cash])
        let candidates = [
            txn("-100", account: giro.id, description: "GELDAUTOMAT 1"),
            txn("-60", account: giro.id, description: "BANKOMAT 2"),
            txn("-12", account: giro.id, description: "BILLA")
        ]
        try await dependencies.transactionRepository.upsert(candidates)
        let useCase = MirrorCashWithdrawal(dependencies: dependencies)

        #expect(try await useCase.mirrorDetectedWithdrawals(in: candidates) == 0)

        preferences.setCashWithdrawalTargetAccountID(cash.id)
        #expect(try await useCase.mirrorDetectedWithdrawals(in: candidates) == 2)
        #expect(try await useCase.mirrorDetectedWithdrawals(in: candidates) == 0)

        var query = TransactionQuery()
        query.accountIDs = [cash.id]
        let mirrored = try await dependencies.transactionRepository.transactions(matching: query)
        #expect(mirrored.map(\.amount.amount).sorted() == [60, 100])
    }
}
