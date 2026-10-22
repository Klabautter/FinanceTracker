import Foundation
import Testing

@testable import FinanceTracker

@Suite("QA-Durchgang 21.10.")
struct QAPolishTests {
    @Test("Händlernamen: Rechtsformen weg, bis zu vier Wörter")
    func merchantNames() {
        let normalizer = MerchantNormalizer()
        #expect(normalizer.canonicalDisplayName(from: "urban - homes for students GmbH") == "urban homes for students")
        #expect(normalizer.canonicalDisplayName(from: "PayPal Europe S.a.r.l. et Cie S.C.A") == "PayPal Europe")
        #expect(normalizer.canonicalDisplayName(from: "Techniker Krankenkasse") == "Techniker Krankenkasse")
        #expect(normalizer.canonicalDisplayName(from: "BAECKEREI MUELLER 1234 WIEN") == "BAECKEREI MUELLER WIEN")
    }

    @Test("Überweisungen bekommen lesbare Namen")
    func transferNames() {
        let broker = CounterpartyClassifier.displayName(
            for: .broker,
            counterparty: Counterparty(name: "Max Mustermann"),
            rawDescription: "Sparplan IBAN: DE00123456789012345678 BIC: TRBKDEBBXXX"
        )
        #expect(broker == "Trade Republic")
        let own = CounterpartyClassifier.displayName(
            for: .ownAccount,
            counterparty: Counterparty(name: "Max Mustermann"),
            rawDescription: "Reisekasse IBAN: DE00123456789012345678 BIC: REVODEB2XXX"
        )
        #expect(own == "Revolut (eigenes Konto)")
        #expect(CounterpartyClassifier.displayName(for: .ownAccount, counterparty: Counterparty(name: "X Y"), rawDescription: nil) == "Eigenes Konto")
    }

    @Test("Lieferdienste landen bei Restaurants")
    func deliveryHero() {
        let transaction = Transaction(
            accountID: UUID(), source: .openBanking, kind: .purchase,
            amount: Money(amount: -45, currency: .eur),
            rawMerchantName: "PayPal Europe", merchantDisplayName: "Delivery Hero Payments"
        )
        #expect(MerchantKeywordCategorizer.categoryID(for: transaction) == Category.restaurants.id)
    }
}

@MainActor
@Suite("Regelliste zeigt Händlernamen")
struct RuleListMerchantNameTests {
    @Test("Händler-Regel nennt den Händler statt „identifiziert“")
    func ruleNames() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        let merchant = Merchant(displayName: "Techniker Krankenkasse", aliases: [])
        try await dependencies.merchantRepository.upsert([merchant])
        let rule = CategoryRule(priority: -1, condition: .merchantIDEquals(merchant.id), categoryID: Category.health.id, enabled: true, origin: .user)
        try await dependencies.ruleRepository.upsert([rule])

        let model = CategoriesModel(dependencies: dependencies)
        await model.load()

        #expect(model.conditionText(for: rule) == "Händler ist „Techniker Krankenkasse“")
        #expect(model.ruleDetailText(for: rule).contains("deine Regel"))
    }
}

@MainActor
@Suite("Analyse vergleicht nur mit gedeckter Vorperiode")
struct AnalyticsTrendCoverageTests {
    @Test("Buchungen erst am Ende der Vorperiode: kein Prozentvergleich")
    func noTrendWithoutCoverage() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let calendar = Calendar(identifier: .gregorian)
        // Vorperiode von „letzte 3 Monate“: nur eine Buchung kurz vor ihrem Ende.
        let monthStart = try #require(calendar.date(from: calendar.dateComponents([.year, .month], from: Date())))
        let lateInPrevious = try #require(calendar.date(byAdding: .day, value: -70, to: monthStart))
        func expense(_ amount: Decimal, _ date: Date) -> Transaction {
            Transaction(accountID: account.id, source: .manual, kind: .purchase,
                        amount: Money(amount: -amount, currency: .eur), bookedAt: date, rawMerchantName: "Test")
        }
        try await dependencies.transactionRepository.upsert([expense(1000, Date()), expense(10, lateInPrevious)])

        let model = AnalyticsModel(dependencies: dependencies, calendar: calendar)
        model.range = .last3Months
        await model.load()

        #expect(model.previousSnapshot?.totalSpending == 10)
        #expect(model.spendingTrendPercent == nil)
    }
}

@MainActor
@Suite("Import: gleiche Zeilen in einer Datei")
struct SameDayDuplicateRowsTests {
    @Test("Zweimal derselbe Einkauf am selben Tag bleibt zweimal, erneuter Import erkennt beide")
    func identicalRowsAreKept() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Testbank", type: .checking, currency: .eur, source: .csvImport)
        try await dependencies.accountRepository.upsert([account])
        let pipeline = ImportPipeline(
            providers: [],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            merchantRepository: dependencies.merchantRepository,
            categoryRepository: dependencies.categoryRepository,
            fallbackCurrency: .eur
        )
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let row = ImportedTransaction(amount: Money(amount: -60.10, currency: .eur), bookedAt: day, rawDescription: "Tanken", rawMerchantName: "Shell")

        let first = try await pipeline.commitParsedTransactions([row, row], source: .genericCSV, providerIdentifier: "t", into: account.id)
        #expect(first.importedCount == 2)
        let second = try await pipeline.commitParsedTransactions([row, row], source: .genericCSV, providerIdentifier: "t", into: account.id)
        #expect(second.importedCount == 0)
        #expect(second.duplicateCount == 2)
        // Ein Auszug mit einer dritten gleichen Buchung bringt genau eine dazu.
        let third = try await pipeline.commitParsedTransactions([row, row, row], source: .genericCSV, providerIdentifier: "t", into: account.id)
        #expect(third.importedCount == 1)
    }
}

@MainActor
@Suite("Manuelle Buchung")
struct ManualEntryPolishTests {
    @Test("Ohne Konto: Bargeld-Konto direkt anlegen; Kategorie aus dem Händlernamen")
    func cashAccountAndSuggestion() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        let model = AddTransactionModel(dependencies: dependencies)
        await model.load()
        #expect(model.accounts.isEmpty)

        await model.createCashAccount()
        #expect(model.accounts.count == 1)
        #expect(model.draft.accountID == model.accounts.first?.id)

        model.draft.merchant = "Bäckerei Müller"
        model.draft.amountText = "12,80"
        #expect(model.suggestedCategory?.id == Category.groceries.id)
        #expect(await model.save())
        let stored = try #require(await dependencies.transactionRepository.transactions(matching: TransactionQuery()).first)
        #expect(stored.categoryID == Category.groceries.id)
    }
}

@MainActor
@Suite("Aufteilen: Anteile höchstens so hoch wie die Ausgabe")
struct GroupShareLimitTests {
    @Test("Ein Anteil über dem Buchungsbetrag wird abgelehnt")
    func shareCannotExceedAmount() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let purchase = Transaction(accountID: account.id, source: .manual, kind: .purchase,
                                   amount: Money(amount: Decimal(string: "-45.67")!, currency: .eur), bookedAt: Date(),
                                   rawMerchantName: "REWE")
        try await dependencies.transactionRepository.upsert([purchase])
        let model = GroupExpenseSectionModel(transaction: purchase, dependencies: dependencies)
        await model.load()

        #expect(await model.addShare(paidBy: "Alex", owedBy: "Mara", amountText: "100", currency: .eur) == false)
        #expect(model.errorMessage != nil)
        #expect(await model.addShare(paidBy: "Alex", owedBy: "Mara", amountText: "20", currency: .eur))
        #expect(await model.addShare(paidBy: "Alex", owedBy: "Tom", amountText: "30", currency: .eur) == false)
        #expect(await model.addShare(paidBy: "Alex", owedBy: "Tom", amountText: "25,67", currency: .eur))
    }
}

@Suite("Internationale Erkennung")
struct InternationalRecognitionTests {
    @Test("Ketten außerhalb DACH werden zugeordnet, Vornamen nicht")
    func chains() {
        #expect(MerchantKeywordCategorizer.categoryID(forMerchantName: "WHOLEFDS MKT 10234") == Category.groceries.id)
        #expect(MerchantKeywordCategorizer.categoryID(forMerchantName: "STARBUCKS STORE 123") == Category.restaurants.id)
        #expect(MerchantKeywordCategorizer.categoryID(forMerchantName: "IKEA Amsterdam") == Category.shopping.id)
        #expect(MerchantKeywordCategorizer.categoryID(forMerchantName: "Boots UK") == Category.health.id)
        #expect(MerchantKeywordCategorizer.categoryID(forMerchantName: "TFL TRAVEL CH") == Category.publicTransport.id)
        #expect(MerchantKeywordCategorizer.categoryID(forMerchantName: "Tim Müller") == nil)
        #expect(MerchantKeywordCategorizer.categoryID(forMerchantName: "Leon Schmidt") == nil)
    }

    @Test("PayPal-Händler in anderen Sprachen")
    func payPalLanguages() {
        let paypal = "PayPal Europe S.a.r.l. et Cie S.C.A"
        #expect(PaymentIntermediaryResolver.underlyingMerchant(rawMerchantName: paypal, rawDescription: "1234/PP.1.PP/. Fnac, Votre achat chez Fnac") == "Fnac")
        #expect(PaymentIntermediaryResolver.underlyingMerchant(rawMerchantName: paypal, rawDescription: "1234/PP.1.PP/. Bol.com, Uw aankoop bij Bol.com") == "Bol.com")
    }

    @Test("Broker und Banken anderer Länder")
    func brokers() {
        #expect(CounterpartyClassifier.isBroker(Counterparty(name: "DEGIRO B.V.")))
        #expect(CounterpartyClassifier.isBroker(Counterparty(name: "Trading 212 Ltd")))
        #expect(CounterpartyClassifier.institutionName(forBIC: "INGBNL2AXXX") == "ING")
    }
}
