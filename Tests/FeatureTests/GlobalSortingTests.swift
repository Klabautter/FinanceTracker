import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

/// WP21: Sortierung ist GLOBAAL über alle Seiten korrekt
/// page1 + page2 kombiniert ergeben die sortierte Gesamtreihenfolge.
@MainActor
@Suite("GlobalSorting")
struct GlobalSortingTests {

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func makeTxn(
        accountID: UUID,
        merchant: String,
        amount: Decimal,
        currency: CurrencyCode = .eur,
        daysAgo: Int
    ) -> Transaction {
        Transaction(
            id: UUID(),
            accountID: accountID,
            source: .demo,
            externalID: "sort-\(UUID().uuidString)",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -amount, currency: currency),
            bookedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()),
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
    }

    private func page(
        _ dependencies: AppDependencies,
        sort: TransactionSortOrder,
        offset: Int,
        limit: Int
    ) async throws -> TransactionPage {
        try await dependencies.transactionRepository.transactionPage(
            matching: TransactionQuery(),
            sort: sort,
            offset: offset,
            limit: limit
        )
    }

    @Test("600 Rows: Merchant-Sortierung über zwei Seiten global korrekt (asc)")
    func merchantGlobalAscending() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        // 600 Rows, Merchants in gemischter Reihenfolge (deterministisch gemischt).
        var rows: [Transaction] = []
        for index in 0..<600 {
            let merchantIndex = (index * 7919) % 600 // Primzahl-Mix
            rows.append(makeTxn(
                accountID: account.id,
                merchant: "Händler \(String(format: "%04d", merchantIndex))",
                amount: Decimal(index + 1),
                daysAgo: index
            ))
        }
        try await dependencies.transactionRepository.upsert(rows)

        let firstPage = try await page(dependencies, sort: .merchantAscending, offset: 0, limit: 300)
        let secondPage = try await page(dependencies, sort: .merchantAscending, offset: 300, limit: 300)

        let combined = firstPage.transactions + secondPage.transactions
        #expect(combined.count == 600)
        #expect(Set(combined.map(\.id)).count == 600) // kein Duplikat, keine Lücke

        // Kombiniert global sortiert (gefoldet).
        for index in 0..<(combined.count - 1) {
            let result = combined[index].effectiveMerchantName
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .compare(
                    combined[index + 1].effectiveMerchantName
                        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil),
                    options: [.caseInsensitive, .diacriticInsensitive]
                )
            #expect(result == .orderedAscending || result == .orderedSame)
        }
    }

    @Test("Merchant-Sortierung global korrekt (desc)")
    func merchantGlobalDescending() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        var rows: [Transaction] = []
        for index in 0..<120 {
            rows.append(makeTxn(
                accountID: account.id,
                merchant: "Händler \(String(format: "%04d", index))",
                amount: 10,
                daysAgo: index
            ))
        }
        try await dependencies.transactionRepository.upsert(rows)

        let combined = (try await page(dependencies, sort: .merchantDescending, offset: 0, limit: 100)).transactions
            + (try await page(dependencies, sort: .merchantDescending, offset: 100, limit: 100)).transactions

        let names = combined.map(\.effectiveMerchantName)
        #expect(names.count == 120)
        for index in 0..<(names.count - 1) {
            let result = names[index].localizedCaseInsensitiveCompare(names[index + 1])
            #expect(result == .orderedDescending || result == .orderedSame)
        }
    }

    @Test("Amount-Sortierung: Währung primär, Betrag sekundär (EUR/USD getrennt)")
    func amountSortCurrencyPrimary() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo),
            Account(name: "Wallet", type: .checking, currency: .usd, source: .blockchain)
        ])
        let accounts = try await dependencies.accountRepository.accounts()
        let eurAccount = try #require(accounts.first { $0.currency == .eur })
        let usdAccount = try #require(accounts.first { $0.currency == .usd })

        var rows: [Transaction] = []
        rows.append(makeTxn(accountID: eurAccount.id, merchant: "EUR-klein", amount: 5, daysAgo: 1))
        rows.append(makeTxn(accountID: eurAccount.id, merchant: "EUR-groß", amount: 500, daysAgo: 2))
        rows.append(makeTxn(accountID: usdAccount.id, merchant: "USD-groß", amount: 400, currency: .usd, daysAgo: 3))
        rows.append(makeTxn(accountID: usdAccount.id, merchant: "USD-klein", amount: 4, currency: .usd, daysAgo: 4))
        try await dependencies.transactionRepository.upsert(rows)

        let ascending = try await page(dependencies, sort: .amountAscending, offset: 0, limit: 10).transactions
        let currencies = ascending.map(\.amount.currency.rawValue)

        // Deterministisch ohne FX: EUR-Block zuerst (alphabetisch), Beträge
        // in der Währung aufsteigend (Ausgaben sind negativ → größte Ausgabe
        // zuerst); dann der USD-Block.
        #expect(currencies == ["EUR", "EUR", "USD", "USD"])
        #expect(ascending[0].amount.amount == -500)
        #expect(ascending[1].amount.amount == -5)
        #expect(ascending[2].amount.amount == -400)
        #expect(ascending[3].amount.amount == -4)
    }

    @Test("Date-Sortierung bleibt global korrekt (asc/desc)")
    func dateSorting() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        var rows: [Transaction] = []
        for index in 0..<100 {
            rows.append(makeTxn(accountID: account.id, merchant: "Händler \(index)", amount: 10, daysAgo: index))
        }
        try await dependencies.transactionRepository.upsert(rows)

        let ascending = (try await page(dependencies, sort: .dateAscending, offset: 0, limit: 60)).transactions
            + (try await page(dependencies, sort: .dateAscending, offset: 60, limit: 60)).transactions
        let descending = (try await page(dependencies, sort: .dateDescending, offset: 0, limit: 60)).transactions
            + (try await page(dependencies, sort: .dateDescending, offset: 60, limit: 60)).transactions

        #expect(ascending.map(\.displayDate) == ascending.map(\.displayDate).sorted())
        #expect(descending.map(\.displayDate) == descending.map(\.displayDate).sorted(by: >))
        #expect(Set(ascending.map(\.id)) == Set(descending.map(\.id)))
    }
}