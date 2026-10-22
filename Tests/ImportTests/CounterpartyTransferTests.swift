import Foundation
import Testing

@testable import FinanceTracker

@Suite("Gegenseite: eigene Konten, Broker, PayPal-Händler")
struct CounterpartyClassifierTests {
    private let owner = ["Max Alexander Mustermann"]

    @Test("Eigener Name in jeder Schreibweise, Verwandte nicht")
    func samePerson() {
        #expect(CounterpartyClassifier.isSamePerson("Max Mustermann", owner[0]))
        #expect(CounterpartyClassifier.isSamePerson("Mustermann, Max", owner[0]))
        #expect(CounterpartyClassifier.isSamePerson("max mustermann", owner[0]))
        #expect(CounterpartyClassifier.isSamePerson("Herrn Max Alexander Mustermann", owner[0]))
        #expect(!CounterpartyClassifier.isSamePerson("Erika Mustermann", owner[0]))
        #expect(!CounterpartyClassifier.isSamePerson("Mustermann", owner[0]))
        #expect(!CounterpartyClassifier.isSamePerson("Mustermann GmbH", owner[0]))
    }

    @Test("Broker an der BIC im Verwendungszweck, vor dem eigenen Namen")
    func brokerFromDescription() {
        let result = CounterpartyClassifier.classify(
            Counterparty(name: "Max Alexander Mustermann"),
            rawDescription: "Sparplan IBAN: DE00123456789012345678 BIC: TRBKDEBBXXX",
            ownerNames: owner
        )
        #expect(result == .broker)
        #expect(result?.categoryID == Category.investments.id)
    }

    @Test("Eigenes Konto bei einer anderen Bank ist eine Umbuchung")
    func ownAccount() {
        let result = CounterpartyClassifier.classify(
            Counterparty(name: "Max Mustermann"),
            rawDescription: "Reisekasse IBAN: DE00123456789012345678 BIC: REVODEB2XXX",
            ownerNames: owner
        )
        #expect(result == .ownAccount)
        #expect(result?.categoryID == Category.transfers.id)
    }

    @Test("Fremde Personen und Händler bleiben unberührt")
    func strangers() {
        #expect(CounterpartyClassifier.classify(Counterparty(name: "Erika Mustermann"), rawDescription: "Grafikkarte", ownerNames: owner) == nil)
        #expect(CounterpartyClassifier.classify(Counterparty(name: "REWE Markt"), rawDescription: nil, ownerNames: owner) == nil)
        #expect(CounterpartyClassifier.classify(Counterparty(name: "Max Mustermann"), rawDescription: nil, ownerNames: []) == nil)
        #expect(CounterpartyClassifier.classify(Counterparty(name: "Trade Republic Bank GmbH"), rawDescription: nil, ownerNames: []) == .broker)
    }

    @Test("PayPal: Händler aus „Ihr Einkauf bei …“")
    func payPalMerchant() {
        let payPal = "PayPal Europe S.a.r.l. et Cie S.C.A"
        func resolve(_ description: String) -> String? {
            PaymentIntermediaryResolver.underlyingMerchant(rawMerchantName: payPal, rawDescription: description)
        }
        #expect(resolve("1052096573908/PP.5628.PP/. dm-drogerie markt GmbH + Co. KG, Ihr Einkauf bei dm-drogerie markt GmbH + Co. KG ER") == "dm-drogerie markt GmbH + Co. KG")
        #expect(resolve("1048602610984/. Parfumo, Ihr Einkauf bei Parfumo EREF: 1048602610984 MREF: X") == "Parfumo")
        #expect(resolve("1051478810683/PP.5628.PP/. www.steampowered.com, Ihr Einkauf bei www.steampowered.com EREF: 1") == "www.steampowered.com")
        #expect(resolve("1053234939819/PP.5628.PP/. , Ihr Einkauf bei EREF: 1053234939819 MREF: 5RY2224SVXYDA") == nil)
        #expect(resolve("PP.5628.PP Ihr Einkauf bei Hetzner Online GmbH EREF: 1") == "Hetzner Online GmbH")
        // Ohne PayPal-Bezug wird nichts umgedeutet.
        #expect(PaymentIntermediaryResolver.underlyingMerchant(rawMerchantName: "Thalia", rawDescription: "Ihr Einkauf bei Thalia") == nil)
    }

    @Test("Enable Banking: Gutschrift nennt den Absender, IBAN/BIC werden übernommen")
    func enableBankingCounterparty() throws {
        let json = """
        {
            "entry_reference": "42",
            "transaction_amount": {"amount": "1034.00", "currency": "EUR"},
            "credit_debit_indicator": "CRDT",
            "status": "BOOK",
            "booking_date": "2026-09-30",
            "creditor": {"name": "Max Alexander Mustermann"},
            "debtor": {"name": "Bundesagentur"},
            "debtor_account": {"iban": "DE00123456789012345678"},
            "debtor_agent": {"bic_fi": "MARKDEF1760"},
            "remittance_information": ["09.2026 Foerd.-Nr: 1"]
        }
        """
        let dto = try JSONDecoder().decode(EnableBankingTransaction.self, from: Data(json.utf8))
        let mapped = try #require(EnableBankingBankDataProvider.map(transaction: dto, accountUID: "acc"))
        #expect(mapped.counterparty.name == "Bundesagentur")
        #expect(mapped.counterparty.iban == "DE00123456789012345678")
        #expect(mapped.counterparty.bic == "MARKDEF1760")
    }
}

@MainActor
@Suite("Bank-Sync: Gegenseite und Umbuchungen")
struct CounterpartySyncTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func makeDependencies() async throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        try await dependencies.ruleRepository.upsert(CategoryRule.defaultCatalog())
        return dependencies
    }

    private func txn(
        _ id: String,
        _ amount: String,
        creditor: String? = nil,
        debtor: String? = nil,
        remittance: String
    ) -> RemoteBankTransaction {
        RemoteBankTransaction(
            externalID: id,
            state: .booked,
            amount: Money(amount: Decimal(string: amount)!, currency: .eur),
            bookingDate: calendar.date(from: DateComponents(year: 2026, month: 9, day: 15)),
            valueDate: calendar.date(from: DateComponents(year: 2026, month: 9, day: 15)),
            creditorName: creditor,
            debtorName: debtor,
            remittanceInformation: remittance
        )
    }

    private func sync(_ provider: MockBankDataProvider, _ dependencies: AppDependencies) async throws -> (BankSyncResult, Connection) {
        let service = BankSyncService(dependencies: dependencies, provider: provider)
        let connection = try await service.connect(
            institution: provider.stubbedInstitutions[0],
            providerConnectionID: "cp",
            linkedAccountIDs: provider.stubbedLinkedAccountIDs
        )
        return (try await service.sync(connection: connection), connection)
    }

    @Test("Eingang zeigt den Absender, nicht den Kontoinhaber")
    func incomingShowsSender() async throws {
        let dependencies = try await makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [
            txn("IN", "1034.00", creditor: "Test User", debtor: "Bundesagentur", remittance: "Förderung")
        ]
        _ = try await sync(provider, dependencies)

        let stored = try #require(await dependencies.transactionRepository.transactions(matching: TransactionQuery()).first)
        #expect(stored.rawMerchantName == "Bundesagentur")
        #expect(stored.kind == .income)
        #expect(stored.categoryID != Category.transfers.id)
    }

    @Test("Umbuchung aufs eigene Konto ist neutral, Broker-Einzahlung ist Geldanlage, Fremde bleiben offen")
    func transfersAndBroker() async throws {
        let dependencies = try await makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [
            txn("OWN", "-400.00", creditor: "User Test", remittance: "Reisekasse IBAN: DE00123456789012345678 BIC: REVODEB2XXX"),
            txn("OWN-IN", "97.63", creditor: "Test User", debtor: "Test User", remittance: "INSTANT TRANSFER"),
            txn("BROKER", "-1000.00", creditor: "Test User", remittance: "Sparplan IBAN: DE00123456789012345678 BIC: TRBKDEBBXXX"),
            txn("FAMILY", "-200.00", creditor: "Anna User", remittance: "Grafikkarte")
        ]
        _ = try await sync(provider, dependencies)

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let byID = Dictionary(uniqueKeysWithValues: stored.compactMap { txn in txn.externalID.map { ($0, txn) } })
        // Gegenkonto nicht in der App: Umbuchung, zählt aber weiter.
        #expect(byID["OWN"]?.categoryID == Category.transfers.id)
        #expect(byID["OWN"]?.kind == .purchase)
        #expect(byID["OWN"]?.isUnlinkedOwnTransfer == true)
        #expect(byID["OWN-IN"]?.categoryID == Category.transfers.id)
        #expect(byID["OWN-IN"]?.kind == .income)
        #expect(byID["BROKER"]?.categoryID == Category.investments.id)
        #expect(byID["BROKER"]?.kind == .purchase)
        #expect(byID["FAMILY"]?.categoryID == nil)
        #expect(CashflowPolicy.shared.contribution(for: try #require(byID["OWN"])) == .spending(400))
    }

    @Test("Neu gemeldete Gegenseite korrigiert eine bekannte Buchung, ohne die Kategorie anzufassen")
    func refetchRefreshesCounterparty() async throws {
        let dependencies = try await makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [
            txn("A", "1034.00", remittance: "Foerd.-Nr 1"),
            txn("B", "50.00", remittance: "Kaution")
        ]
        let (_, connection) = try await sync(provider, dependencies)

        // Kategorie von B hat der Nutzer schon vergeben.
        var stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        var userCategorized = try #require(stored.first { $0.externalID == "B" })
        userCategorized.categoryID = Category.income.id
        try await dependencies.transactionRepository.upsert([userCategorized])

        provider.stubbedTransactions = [
            txn("A", "1034.00", creditor: "Test User", debtor: "Test User", remittance: "Foerd.-Nr 1"),
            txn("B", "50.00", creditor: "Test User", debtor: "Test User", remittance: "Kaution")
        ]
        let service = BankSyncService(dependencies: dependencies, provider: provider)
        let result = try await service.sync(connection: connection)
        #expect(result.updatedCount == 2)
        #expect(result.importedCount == 0)

        stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.count == 2)
        let refreshedA = try #require(stored.first { $0.externalID == "A" })
        #expect(refreshedA.rawMerchantName == "Test User")
        #expect(refreshedA.categoryID == Category.transfers.id)
        #expect(refreshedA.kind == .income)
        let refreshedB = try #require(stored.first { $0.externalID == "B" })
        #expect(refreshedB.rawMerchantName == "Test User")
        #expect(refreshedB.categoryID == Category.income.id)
        #expect(refreshedB.kind == .income)
    }

    @Test("Frühere offene Belastungen werden beim Abruf nachträglich eingeordnet")
    func earlierDebitsAreClassified() async throws {
        let dependencies = try await makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = []
        let (_, connection) = try await sync(provider, dependencies)
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let earlier = [
            Transaction(accountID: account.id, source: .openBanking, externalID: "old-1", kind: .purchase,
                        amount: Money(amount: -2000, currency: .eur),
                        rawDescription: "Sparplan IBAN: DE00123456789012345678 BIC: TRBKDEBBXXX", rawMerchantName: "Test User"),
            Transaction(accountID: account.id, source: .openBanking, externalID: "old-2", kind: .purchase,
                        amount: Money(amount: -600, currency: .eur),
                        rawDescription: "Reisekasse", rawMerchantName: "Test User"),
            // Alte Gutschriften trugen den Inhaber als Gegenseite, bleiben unangetastet.
            Transaction(accountID: account.id, source: .openBanking, externalID: "old-3", kind: .income,
                        amount: Money(amount: 1034, currency: .eur),
                        rawDescription: "Foerd.-Nr", rawMerchantName: "Test User")
        ]
        try await dependencies.transactionRepository.upsert(earlier)

        _ = try await BankSyncService(dependencies: dependencies, provider: provider).sync(connection: connection)

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.first { $0.externalID == "old-1" }?.categoryID == Category.investments.id)
        #expect(stored.first { $0.externalID == "old-2" }?.categoryID == Category.transfers.id)
        #expect(stored.first { $0.externalID == "old-2" }?.kind == .purchase)
        #expect(stored.first { $0.externalID == "old-3" }?.categoryID == nil)
        #expect(stored.first { $0.externalID == "old-3" }?.kind == .income)
    }

    @Test("Kommt das Gegenkonto dazu, werden beide Seiten verknüpft und neutral")
    func linkingWhenCounterAccountArrives() async throws {
        let dependencies = try await makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [
            txn("OUT", "-400.00", creditor: "Test User", remittance: "Reisekasse"),
            txn("OTHER", "-400.00", creditor: "Anna User", remittance: "Miete")
        ]
        _ = try await sync(provider, dependencies)
        var stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(stored.first { $0.externalID == "OUT" }?.kind == .purchase)

        // Zweites eigenes Konto mit der Gegenbuchung, z. B. per Datei-Import.
        let other = Account(name: "Revolut", type: .checking, currency: .eur, source: .csvImport)
        try await dependencies.accountRepository.upsert([other])
        let incoming = ImportedTransaction(
            externalID: "rev-1",
            amount: Money(amount: 400, currency: .eur),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: 9, day: 16)),
            rawDescription: "Top-up",
            rawMerchantName: "Top-up"
        )
        let pipeline = ImportPipeline(
            providers: [],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            merchantRepository: dependencies.merchantRepository,
            categoryRepository: dependencies.categoryRepository,
            fallbackCurrency: .eur
        )
        _ = try await pipeline.commitParsedTransactions(
            [incoming], source: .genericCSV, providerIdentifier: "test", into: other.id
        )

        stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let out = try #require(stored.first { $0.externalID == "OUT" })
        let into = try #require(stored.first { $0.externalID == "rev-1" })
        #expect(out.kind == .transfer)
        #expect(into.kind == .transfer)
        #expect(into.categoryID == Category.transfers.id)
        #expect(CashflowPolicy.shared.contribution(for: out) == .neutral)
        // Die Überweisung an Anna bleibt eine Ausgabe.
        #expect(stored.first { $0.externalID == "OTHER" }?.kind == .purchase)
    }

    @Test("Personen bekommen keine Händler-Rückfrage")
    func personNames() {
        #expect(PersonNameDetector.isPersonName("Anna Schmidt"))
        #expect(PersonNameDetector.isPersonName("Thomas Weber"))
        #expect(!PersonNameDetector.isPersonName("Techniker Krankenkasse"))
        #expect(!PersonNameDetector.isPersonName("Hetzner Online GmbH"))
        #expect(!PersonNameDetector.isPersonName("Amazon"))
        #expect(!PersonNameDetector.isPersonName("DB Vertrieb GmbH"))
    }

    @Test("PayPal-Buchung bekommt den Händler hinter der Zahlung")
    func payPalImport() async throws {
        let dependencies = try await makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [
            txn("PP", "-16.64", creditor: "PayPal Europe S.a.r.l. et Cie S.C.A",
                remittance: "1051427107869/PP.5628.PP/. Hetzner Online GmbH, Ihr Einkauf bei Hetzner Online GmbH EREF: 1051427107869"),
            txn("PP-FRIEND", "-10.00", creditor: "PayPal Europe S.a.r.l. et Cie S.C.A",
                remittance: "1051918221394/PP.5628.PP/. , Ihr Einkauf bei EREF: 1051918221394")
        ]
        _ = try await sync(provider, dependencies)

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let hetzner = try #require(stored.first { $0.externalID == "PP" })
        #expect(hetzner.merchantDisplayName?.localizedCaseInsensitiveContains("Hetzner") == true)
        #expect(hetzner.rawMerchantName == "PayPal Europe S.a.r.l. et Cie S.C.A")
        let friend = try #require(stored.first { $0.externalID == "PP-FRIEND" })
        #expect(friend.merchantDisplayName?.localizedCaseInsensitiveContains("PayPal") == true)
    }

    @Test("Katalog-Rückfill holt den PayPal-Händler für vorhandene Buchungen nach")
    func payPalBackfill() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([account])
        let existing = Transaction(
            accountID: account.id, source: .openBanking, externalID: "pp-old", kind: .purchase,
            amount: Money(amount: Decimal(string: "-9.70")!, currency: .eur),
            rawDescription: "1052096573908/PP.5628.PP/. dm-drogerie markt GmbH + Co. KG, Ihr Einkauf bei dm-drogerie markt",
            rawMerchantName: "PayPal Europe S.a.r.l. et Cie S.C.A",
            merchantDisplayName: "PayPal"
        )
        try await dependencies.transactionRepository.upsert([existing])

        let defaults = try #require(UserDefaults(suiteName: "paypal-backfill-\(UUID().uuidString)"))
        await SystemCatalogSeeder(dependencies: dependencies, defaults: defaults).seedIfNeeded()

        let stored = try #require(await dependencies.transactionRepository.transactions(matching: TransactionQuery()).first)
        #expect(stored.merchantDisplayName?.localizedCaseInsensitiveContains("dm") == true)
        #expect(stored.merchantDisplayName?.localizedCaseInsensitiveContains("PayPal") == false)
    }
}
