import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("AddTransaction")
struct AddTransactionTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func makeModel(_ dependencies: AppDependencies) -> AddTransactionModel {
        let model = AddTransactionModel(dependencies: dependencies)
        return model
    }

    @Test("Kategorieauswahl passt zur Art: keine Einkünfte/Umbuchungen bei Ausgaben")
    func categoryOptionsFollowKind() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        let model = makeModel(dependencies)
        await model.load()

        model.draft.kind = .expense
        let expenseIDs = Set(model.categoryOptions.map(\.id))
        #expect(!expenseIDs.contains(Category.income.id))
        #expect(!expenseIDs.contains(Category.transfers.id))
        #expect(expenseIDs.contains(Category.groceries.id))

        model.draft.kind = .income
        let incomeIDs = Set(model.categoryOptions.map(\.id))
        #expect(incomeIDs.contains(Category.income.id))
        #expect(!incomeIDs.contains(Category.transfers.id))

        // Wechsel der Art leert eine nicht mehr passende Kategorie.
        model.draft.categoryID = Category.income.id
        model.draft.kind = .expense
        model.dropUnavailableCategory()
        #expect(model.draft.categoryID == nil)
    }

    @Test("Ausgabe wird mit negativem Betrag und source manual gespeichert")
    func saveExpense() async throws {
        let dependencies = try makeDependencies()
        let model = makeModel(dependencies)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        await model.load()

        model.draft.kind = .expense
        model.draft.amountText = "42,50"
        model.draft.merchant = "REWE"
        model.draft.accountID = model.accounts.first?.id
        model.draft.note = "Wocheneinkauf"

        let saved = await model.save()
        #expect(saved)

        let page = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(), sort: .dateDescending, offset: 0, limit: 10
        )
        #expect(page.transactions.count == 1)
        let txn = try #require(page.transactions.first)
        #expect(txn.source == .manual)
        #expect(txn.kind == .purchase)
        #expect(txn.amount.amount == Decimal(string: "-42.50")!)
        #expect(txn.merchantDisplayName == "REWE")
        #expect(txn.note == "Wocheneinkauf")
    }

    @Test("Einnahme wird mit positivem Betrag und kind income gespeichert")
    func saveIncome() async throws {
        let dependencies = try makeDependencies()
        let model = makeModel(dependencies)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        await model.load()

        model.draft.kind = .income
        model.draft.amountText = "1200"
        model.draft.merchant = "Acme GmbH"
        model.draft.accountID = model.accounts.first?.id

        let saved = await model.save()
        #expect(saved)

        let page = try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(), sort: .dateDescending, offset: 0, limit: 10
        )
        let txn = try #require(page.transactions.first)
        #expect(txn.kind == .income)
        #expect(txn.amount.amount == Decimal(1200))
    }

    @Test("Validierung: ungültiger Betrag und fehlender Händler werden abgelehnt")
    func validation() async throws {
        let dependencies = try makeDependencies()
        let model = makeModel(dependencies)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        await model.load()

        model.draft.amountText = "abc"
        model.draft.merchant = "X"
        model.draft.accountID = model.accounts.first?.id
        #expect(await model.save() == false)

        model.draft.amountText = "-5"
        #expect(await model.save() == false)

        model.draft.amountText = "10"
        model.draft.merchant = ""
        #expect(await model.save() == false)

        let count = try await dependencies.transactionRepository.count()
        #expect(count == 0)
    }

    @Test("Tags und Notiz landen in der Annotation (Roadmap #62-Regel)")
    func tagsGoToAnnotation() async throws {
        let dependencies = try makeDependencies()
        let model = makeModel(dependencies)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let tag = Tag(name: "Urlaub", colorToken: .blue)
        try await dependencies.tagRepository.upsert([tag])
        await model.load()

        model.draft.kind = .expense
        model.draft.amountText = "10"
        model.draft.merchant = "Pizzeria"
        model.draft.accountID = model.accounts.first?.id
        model.draft.tagIDs = [tag.id]

        #expect(await model.save())

        let annotation = try await dependencies.transactionAnnotationRepository.annotations().first
        #expect(annotation?.tagIDs?.contains(tag.id) == true)
    }
}

@MainActor
@Suite("ManualTransfer")
struct ManualTransferTests {
    @Test("Transfer persistiert Formular-Konten, Datum, Notiz und Tags genau einmal")
    func transferPair() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let model = AddTransactionModel(dependencies: dependencies)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo),
            Account(name: "Tagesgeld", type: .savings, currency: .eur, source: .demo)
        ])
        let tag = Tag(name: "Umbuchung", colorToken: .blue)
        try await dependencies.tagRepository.upsert([tag])
        await model.load()
        let accounts = try #require(await dependencies.accountRepository.accounts())
        let giro = try #require(accounts.first { $0.name == "Giro" })
        let tagesgeld = try #require(accounts.first { $0.name == "Tagesgeld" })

        model.draft.kind = .transfer
        model.draft.amountText = "500"
        model.draft.accountID = nil
        model.transferDraft.fromAccountID = giro.id
        model.transferDraft.toAccountID = tagesgeld.id
        let transferDate = Date(timeIntervalSince1970: 1_700_000_000)
        model.draft.date = transferDate
        model.draft.note = "  Spartransfer  "
        model.draft.tagIDs = [tag.id]

        #expect(await model.save() == true)
        #expect(await model.save() == false, "Ein erfolgreich gespeicherter Draft darf nicht doppelt gespeichert werden")

        let all = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(all.count == 2)

        let outgoing = try #require(all.first { $0.accountID == giro.id })
        #expect(outgoing.kind == .transfer)
        #expect(outgoing.amount.amount == Decimal(string: "-500.00")!)
        #expect(outgoing.bookedAt == transferDate)
        #expect(outgoing.note == "Spartransfer")
        #expect(outgoing.tagIDs == [tag.id])

        let incoming = try #require(all.first { $0.accountID == tagesgeld.id })
        #expect(incoming.kind == .transfer)
        #expect(incoming.amount.amount == Decimal(string: "500.00")!)
        #expect(incoming.bookedAt == transferDate)
        #expect(incoming.note == "Spartransfer")
        #expect(incoming.tagIDs == [tag.id])

        let annotations = try await dependencies.transactionAnnotationRepository.annotations()
        #expect(annotations.count == 2)
        #expect(annotations.allSatisfy { $0.note == "Spartransfer" && $0.tagIDs == [tag.id] })

        // Pair-Link: gemeinsame externalID-Basis („manual-transfer-…:from/to“)
        let outBase = outgoing.externalID?.split(separator: ":").first
        let inBase = incoming.externalID?.split(separator: ":").first
        #expect(outBase == inBase)

        // Cashflow-neutral: keine der beiden zählt als purchase/income
        let policy = CashflowPolicy.shared
        for txn in all {
            if case .neutral = policy.contribution(for: txn) { continue }
            Issue.record("Transfer-TXN ist nicht neutral: \(txn.kind)")
        }
    }

    @Test("Transfer zwischen unterschiedlichen Kontowährungen wird ohne Umrechnung abgelehnt")
    func crossCurrencyTransferRejected() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let model = AddTransactionModel(dependencies: dependencies)
        let eur = Account(name: "EUR", type: .checking, currency: .eur, source: .demo)
        let usd = Account(name: "USD", type: .checking, currency: .usd, source: .demo)
        try await dependencies.accountRepository.upsert([eur, usd])
        await model.load()

        model.draft.kind = .transfer
        model.draft.amountText = "25"
        model.transferDraft.fromAccountID = eur.id
        model.transferDraft.toAccountID = usd.id

        #expect(await model.save() == false)
        #expect(try await dependencies.transactionRepository.count() == 0)
    }

    @Test("Transfer-Validierung: gleiche Konten werden abgelehnt")
    func sameAccountRejected() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let model = AddTransactionModel(dependencies: dependencies)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        await model.load()
        let account = try #require(await dependencies.accountRepository.accounts().first)

        model.draft.kind = .transfer
        model.draft.accountID = account.id
        model.transferDraft.fromAccountID = account.id
        model.transferDraft.toAccountID = account.id
        model.draft.amountText = "100"

        #expect(await model.save() == false)
        #expect(model.errorMessage != nil)
    }
}
