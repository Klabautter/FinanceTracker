import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@MainActor
@Suite("CommandPalette")
struct CommandPaletteTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    @Test("Sektions-Einträge decken alle Bereiche ab")
    func sectionEntries() async {
        let dependencies = try! makeDependencies()
        let model = CommandPaletteModel(dependencies: dependencies, privacyState: PrivacyPresentationState())
        await model.loadStaticEntries()

        let entries = model.sectionEntries()
        #expect(entries.count == AppSection.allCases.count)
        #expect(entries.contains { $0.title == "Transaktionen" })
    }

    @Test("Konten/Kategorien/Tags filtern nach Query")
    func staticFiltering() async throws {
        let dependencies = try makeDependencies()
        let model = CommandPaletteModel(dependencies: dependencies, privacyState: PrivacyPresentationState())

        try await dependencies.accountRepository.upsert([
            Account(name: "Girokonto", type: .checking, currency: .eur, source: .demo)
        ])
        try await dependencies.categoryRepository.upsert([
            Category(name: "Lebensmittel", systemIconName: "cart")
        ])
        try await dependencies.tagRepository.upsert([
            Tag(name: "Italien 2026", colorToken: .blue)
        ])
        await model.loadStaticEntries()

        #expect(model.accountEntries(query: "giro").count == 1)
        #expect(model.accountEntries(query: "xyz").isEmpty)
        #expect(model.categoryEntries(query: "lebens").count == 1)
        #expect(model.tagEntries(query: "italien").count == 1)
    }

    @Test("Transaktions-Suche läuft über DB-Pushdown")
    func transactionSearch() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let model = CommandPaletteModel(dependencies: dependencies, privacyState: PrivacyPresentationState())

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        let calendar = Calendar(identifier: .gregorian)
        try await dependencies.transactionRepository.upsert([
            Transaction(
                id: UUID(), accountID: account.id, source: .demo, externalID: "cp-1",
                status: .booked, kind: .purchase,
                amount: Money(amount: -Decimal(string: "12.34")!, currency: .eur),
                bookedAt: calendar.date(byAdding: .day, value: -1, to: Date()),
                rawDescription: "REWE 42",
                rawMerchantName: "REWE", merchantDisplayName: "REWE"
            )
        ])

        // Debug: Row + searchableText direkt prüfen
        let probeContext = ModelContext(store.container)
        let all = try probeContext.fetch(FetchDescriptor<SDTransactionEntity>())
        #expect(all.count == 1)
        print("DBG searchableText:", all.first?.searchableText ?? "nil")

        let results = await model.transactionEntries(query: "rewe")
        #expect(results.count == 1)
        #expect(results.first?.title == "REWE")

        let empty = await model.transactionEntries(query: "")
        #expect(empty.isEmpty)
    }

    @Test("Transaktions-Subtitle maskiert Betrag bei Privacy ON")
    func transactionSubtitlePrivacy() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let privacy = PrivacyPresentationState()
        privacy.hidesAmounts = true
        let model = CommandPaletteModel(dependencies: dependencies, privacyState: privacy)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        let calendar = Calendar(identifier: .gregorian)
        try await dependencies.transactionRepository.upsert([
            Transaction(
                id: UUID(), accountID: account.id, source: .demo, externalID: "cp-privacy-1",
                status: .booked, kind: .purchase,
                amount: Money(amount: -Decimal(string: "12.34")!, currency: .eur),
                bookedAt: calendar.date(byAdding: .day, value: -1, to: Date()),
                rawDescription: "BILLA 7",
                rawMerchantName: "BILLA", merchantDisplayName: "BILLA"
            )
        ])

        let results = await model.transactionEntries(query: "billa")
        #expect(results.count == 1)
        let subtitle = try #require(results.first?.subtitle)
        #expect(subtitle.contains("•••"))
        #expect(!subtitle.contains("12,34"))
        #expect(!subtitle.contains("12.34"))
    }
}

// MARK: - Such-Pfad Regression (transactionPage mit searchText)

@MainActor
@Suite("TransactionSearchPage")
struct TransactionSearchPageTests {
    @Test("transactionPage mit searchText findet Treffer (In-Memory-Suchfilter)")
    func searchPageFindsMatches() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        let calendar = Calendar(identifier: .gregorian)

        var rows: [Transaction] = []
        let fixtures = [
            ("REWE 111", "REWE"),
            ("SHELL 222", "SHELL"),
            ("REWE 333", "REWE"),
            ("AMAZON 444", "Amazon")
        ]
        for (index, fixture) in fixtures.enumerated() {
            rows.append(Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: "search-\(index)",
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -Decimal(index + 1), currency: .eur),
                bookedAt: calendar.date(byAdding: .day, value: -index, to: Date()),
                rawDescription: fixture.0,
                rawMerchantName: fixture.1,
                merchantDisplayName: fixture.1
            ))
        }
        try await dependencies.transactionRepository.upsert(rows)

        // REGRESSION: CONTAINS auf optionale Strings ist SQL-seitig nicht
        // generierbar, die Seite muss den Suchtext in-memory filtern.
        var query = TransactionQuery()
        query.searchText = "rewe"

        let page = try await dependencies.transactionRepository.transactionPage(
            matching: query,
            sort: .dateDescending,
            offset: 0,
            limit: 50
        )
        #expect(page.transactions.count == 2)
        #expect(Set(page.transactions.compactMap(\.externalID)) == ["search-0", "search-2"])

        // Umlaut-/Case-unabhängig
        var umlautQuery = TransactionQuery()
        umlautQuery.searchText = "amazon"
        let umlautPage = try await dependencies.transactionRepository.transactionPage(
            matching: umlautQuery,
            sort: .dateDescending,
            offset: 0,
            limit: 50
        )
        #expect(umlautPage.transactions.count == 1)
        #expect(umlautPage.transactions.first?.merchantDisplayName == "Amazon")
    }
}

@MainActor
@Suite("SearchNote")
struct SearchNoteTests {
    @Test("Suche trifft über die Notiz (buildSearchable inkl. note)")
    func noteSearch() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        let txn = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .demo,
            externalID: "note-1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(10), currency: .eur),
            bookedAt: Date(),
            rawDescription: "BARZAHLUNG",
            rawMerchantName: "SPAR",
            merchantDisplayName: "SPAR",
            note: "Restauration Küchenumbau"
        )
        try await dependencies.transactionRepository.upsert([txn])

        var query = TransactionQuery()
        query.searchText = "küchenumbau"
        let page = try await dependencies.transactionRepository.transactionPage(
            matching: query,
            sort: .dateDescending,
            offset: 0,
            limit: 50
        )
        #expect(page.transactions.count == 1)
        #expect(page.transactions.first?.merchantDisplayName == "SPAR")
    }
}
