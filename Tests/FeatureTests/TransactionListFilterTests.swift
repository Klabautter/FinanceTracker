import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@Suite("Transaktionsliste: Konto-, Zeitraum- und Statusfilter")
@MainActor
struct TransactionListFilterTests {
    private let calendar = Calendar.current

    private func transaction(account: Account, daysAgo: Int, status: TransactionStatus, merchant: String) -> Transaction {
        Transaction(
            accountID: account.id,
            source: .openBanking,
            status: status,
            kind: .purchase,
            amount: Money(amount: -10, currency: .eur),
            bookedAt: calendar.date(byAdding: .day, value: -daysAgo, to: Date())!,
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
    }

    private func makeModel() async throws -> (TransactionsModel, Account, Account) {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let giro = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        let card = Account(name: "Karte", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([giro, card])
        try await dependencies.transactionRepository.upsert([
            transaction(account: giro, daysAgo: 1, status: .booked, merchant: "Giro neu"),
            transaction(account: giro, daysAgo: 200, status: .booked, merchant: "Giro alt"),
            transaction(account: card, daysAgo: 2, status: .pending, merchant: "Karte offen"),
            transaction(account: card, daysAgo: 3, status: .booked, merchant: "Karte gebucht")
        ])
        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()
        return (model, giro, card)
    }

    private func names(_ model: TransactionsModel) -> Set<String> {
        Set(model.visibleTransactions.map(\.effectiveMerchantName))
    }

    @Test("Kontofilter zeigt nur Buchungen dieses Kontos")
    func accountFilter() async throws {
        let (model, giro, _) = try await makeModel()
        model.filterAccountID = giro.id
        await model.filterReloadTask?.value
        #expect(names(model) == ["Giro neu", "Giro alt"])
        #expect(model.activeFilterCount == 1)
    }

    @Test("Statusfilter zeigt nur ausstehende Buchungen")
    func statusFilter() async throws {
        let (model, _, _) = try await makeModel()
        model.filterStatus = .pending
        await model.filterReloadTask?.value
        #expect(names(model) == ["Karte offen"])
    }

    @Test("Zeitraumfilter schließt ältere Buchungen aus, Kombination und Zurücksetzen")
    func periodFilterCombinesAndResets() async throws {
        let (model, giro, _) = try await makeModel()
        model.filterPeriod = .last30Days
        await model.filterReloadTask?.value
        #expect(names(model) == ["Giro neu", "Karte offen", "Karte gebucht"])

        model.filterAccountID = giro.id
        await model.filterReloadTask?.value
        #expect(names(model) == ["Giro neu"])
        #expect(model.activeFilterCount == 2)

        model.resetFilters()
        await model.filterReloadTask?.value
        #expect(model.activeFilterCount == 0)
        #expect(model.visibleTransactions.count == 4)
    }

    @Test("Zeitraum-Intervalle sind halboffen und lückenlos")
    func periodIntervals() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15))!

        let thisMonth = try #require(TransactionPeriodFilter.thisMonth.interval(now: now, calendar: utc))
        let lastMonth = try #require(TransactionPeriodFilter.lastMonth.interval(now: now, calendar: utc))
        #expect(thisMonth.start == utc.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        #expect(thisMonth.end == utc.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        #expect(lastMonth.end == thisMonth.start)

        let last30 = try #require(TransactionPeriodFilter.last30Days.interval(now: now, calendar: utc))
        #expect(last30.start == utc.date(from: DateComponents(year: 2026, month: 9, day: 13)))
        #expect(last30.end == utc.date(from: DateComponents(year: 2026, month: 10, day: 13)))

        let lastYear = try #require(TransactionPeriodFilter.lastYear.interval(now: now, calendar: utc))
        #expect(lastYear.start == utc.date(from: DateComponents(year: 2025, month: 1, day: 1)))
        #expect(lastYear.end == utc.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        #expect(TransactionPeriodFilter.all.interval(now: now, calendar: utc) == nil)
    }

    @Test("Filter und Suche ändern die Reihenfolge innerhalb eines Tages nicht")
    func filteredOrderMatchesUnfilteredOrder() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let giro = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([giro])
        let day = calendar.startOfDay(for: Date())
        let food = Category.groceries.id
        // Gleiches Buchungsdatum, unterschiedliche Anlagezeiten.
        var rows: [Transaction] = []
        for (index, name) in ["Laden A", "Laden B", "Laden C", "Laden D"].enumerated() {
            var txn = Transaction(
                accountID: giro.id, source: .openBanking, status: .booked, kind: .purchase,
                amount: Money(amount: -Decimal(index + 1), currency: .eur), bookedAt: day,
                rawDescription: name, rawMerchantName: name, merchantDisplayName: name,
                categoryID: food
            )
            txn.createdAt = day.addingTimeInterval(Double(index) * 60)
            rows.append(txn)
        }
        try await dependencies.transactionRepository.upsert(rows)

        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()
        let unfiltered = model.visibleTransactions.map(\.effectiveMerchantName)
        #expect(unfiltered.count == 4)

        model.filterStatus = .booked
        await model.filterReloadTask?.value
        #expect(model.visibleTransactions.map(\.effectiveMerchantName) == unfiltered)

        model.resetFilters()
        await model.filterReloadTask?.value
        model.filterCategoryID = food
        await model.filterChanged().value
        #expect(model.visibleTransactions.map(\.effectiveMerchantName) == unfiltered)

        model.resetFilters()
        await model.filterReloadTask?.value
        model.searchText = "Laden"
        await model.filterChanged().value
        #expect(model.visibleTransactions.map(\.effectiveMerchantName) == unfiltered)
    }

    @Test("Eigener Zeitraum: beide Grenztage zählen mit, Änderung der Grenzen lädt neu")
    func customPeriod() async throws {
        let (model, _, _) = try await makeModel()
        let today = Date()
        // Buchungen liegen 1, 2, 3 und 200 Tage zurück.
        model.filterCustomStart = calendar.date(byAdding: .day, value: -3, to: today)!
        model.filterCustomEnd = calendar.date(byAdding: .day, value: -2, to: today)!
        model.filterPeriod = .custom
        await model.filterReloadTask?.value
        #expect(names(model) == ["Karte offen", "Karte gebucht"])
        #expect(model.activeFilterCount == 1)

        model.filterCustomEnd = calendar.date(byAdding: .day, value: -1, to: today)!
        await model.filterReloadTask?.value
        #expect(names(model) == ["Giro neu", "Karte offen", "Karte gebucht"])

        model.filterCustomStart = calendar.date(byAdding: .day, value: -300, to: today)!
        await model.filterReloadTask?.value
        #expect(model.visibleTransactions.count == 4)
    }

    @Test("Eigenes Intervall ist halboffen und ordnet vertauschte Grenzen")
    func customIntervalBounds() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let first = utc.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 17))!
        let last = utc.date(from: DateComponents(year: 2026, month: 8, day: 28, hour: 9))!
        let interval = try #require(TransactionPeriodFilter.customInterval(from: first, through: last, calendar: utc))
        #expect(interval.start == utc.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        #expect(interval.end == utc.date(from: DateComponents(year: 2026, month: 8, day: 29)))
        #expect(TransactionPeriodFilter.customInterval(from: last, through: first, calendar: utc) == interval)
        #expect(TransactionPeriodFilter.custom.interval(now: first, calendar: utc) == nil)
    }
}
