import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@Suite("BudgetRolloverCalculator")
struct BudgetRolloverCalculatorTests {

    private let calculator = BudgetRolloverCalculator()

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    private var previousInterval: DateInterval {
        let start = calendar.date(from: DateComponents(year: 2026, month: 2, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        return DateInterval(start: start, end: end)
    }

    private func budget(policy: BudgetRolloverPolicy) -> Budget {
        Budget(name: "Test", amount: 100, rolloverPolicy: policy)
    }

    private func historyEntry(budgetID: UUID, periodStart: Date, amount: Decimal) -> BudgetAmountHistory {
        BudgetAmountHistory(budgetID: budgetID, periodStart: periodStart, amount: amount)
    }

    @Test("Accumulate: Rest der Vorperiode wird übertragen (100 − 40 = 60)")
    func accumulateCarries() {
        let budget = budget(policy: .accumulate)
        let carry = calculator.carriedOver(
            budget: budget,
            previousInterval: previousInterval,
            previousSpent: 40,
            amountHistory: []
        )
        #expect(carry == 60)
    }

    @Test("Overbudget-Policy: Carry wird auf 0 geklemmt (keine Schuldübertrag)")
    func overbudgetFloorsAtZero() {
        let budget = budget(policy: .accumulate)
        let carry = calculator.carriedOver(
            budget: budget,
            previousInterval: previousInterval,
            previousSpent: 150,
            amountHistory: []
        )
        #expect(carry == 0)
    }

    @Test("Reset-Policy: kein Rollover")
    func resetCarriesNothing() {
        let budget = budget(policy: .reset)
        let carry = calculator.carriedOver(
            budget: budget,
            previousInterval: previousInterval,
            previousSpent: 0,
            amountHistory: []
        )
        #expect(carry == 0)
    }

    @Test("History-aware: Vorperioden-Limit aus BudgetAmountHistory, nicht aktuelles Limit")
    func historyAwareLimit() {
        let budget = budget(policy: .accumulate) // aktuelles Limit 100
        let febStart = calendar.date(from: DateComponents(year: 2026, month: 2, day: 1))!
        let janStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!

        // Gültig für Februar: 80 (jüngster Eintrag ≤ Feb-Start); Jan: 120.
        let history = [
            historyEntry(budgetID: budget.id, periodStart: janStart, amount: 120),
            historyEntry(budgetID: budget.id, periodStart: febStart, amount: 80)
        ]

        // Februar: 80 − 30 = 50 Carry in den März.
        let carry = calculator.carriedOver(
            budget: budget,
            previousInterval: previousInterval,
            previousSpent: 30,
            amountHistory: history
        )
        #expect(carry == 50)
    }

    @Test("History: Eintrag erst NACH dem Vorperioden-Start gilt nicht")
    func historyIgnoresFutureEntries() {
        let budget = budget(policy: .accumulate)
        // Eintrag ab März (aktuelle Periode), gilt nicht für Februar.
        let marchStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let history = [
            historyEntry(budgetID: budget.id, periodStart: marchStart, amount: 500)
        ]

        let carry = calculator.carriedOver(
            budget: budget,
            previousInterval: previousInterval,
            previousSpent: 40,
            amountHistory: history
        )
        // Fällt auf budget.amount (100) zurück: 100 − 40 = 60.
        #expect(carry == 60)
    }
}

@MainActor
@Suite("BudgetRolloverIntegration")
struct BudgetRolloverIntegrationTests {

    @Test("Mehrmonatiger Carry verwendet Periodenlimits und stimmt mit dem Dashboard überein")
    func modelAppliesMultiMonthCarryConsistently() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let januaryStart = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let februaryStart = try #require(calendar.date(from: DateComponents(year: 2026, month: 2, day: 1)))
        let marchStart = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12)))

        let categoryID = UUID()
        let budgetID = UUID()
        try await dependencies.budgetRepository.upsert([
            Budget(
                id: budgetID,
                name: "Rücklage",
                amount: 100,
                categoryIDs: [categoryID],
                rolloverPolicy: .accumulate,
                createdAt: januaryStart
            )
        ])
        try await dependencies.budgetRepository.upsertAmountHistory(BudgetAmountHistory(
            budgetID: budgetID,
            periodStart: januaryStart,
            amount: 120
        ))
        try await dependencies.budgetRepository.upsertAmountHistory(BudgetAmountHistory(
            budgetID: budgetID,
            periodStart: februaryStart,
            amount: 80
        ))
        try await dependencies.budgetRepository.upsertAmountHistory(BudgetAmountHistory(
            budgetID: budgetID,
            periodStart: marchStart,
            amount: 100
        ))

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        func expense(_ amount: Decimal, date: Date) -> Transaction {
            Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: UUID().uuidString,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -amount, currency: .eur),
                bookedAt: date,
                rawDescription: "Einkauf",
                rawMerchantName: "Einkauf",
                merchantDisplayName: "Einkauf",
                categoryID: categoryID
            )
        }

        try await dependencies.transactionRepository.upsert([
            expense(30, date: calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!),
            expense(40, date: calendar.date(from: DateComponents(year: 2026, month: 2, day: 15))!),
            expense(25, date: calendar.date(from: DateComponents(year: 2026, month: 3, day: 15))!)
        ])

        let model = BudgetsModel(dependencies: dependencies, calendar: calendar, now: { now })
        await model.load()

        let progress = try #require(model.progresses.first)
        // Januar: 120 − 30 = 90; Februar: 90 + 80 − 40 = 130.
        #expect(progress.carriedOver == 130)
        #expect(progress.spent == 25)
        #expect(progress.limit == 100)
        #expect(progress.effectiveLimit == 230) // aktuelles Limit 100 + Carry 130
        #expect(progress.remaining == 205)
        #expect(!progress.isOverBudget)

        let dashboard = DashboardModel(dependencies: dependencies, calendar: calendar, now: { now })
        await dashboard.load()
        let dashboardProgress = try #require(dashboard.budgetProgresses.first)
        #expect(dashboardProgress.period == progress.period)
        #expect(dashboardProgress.spent == progress.spent)
        #expect(dashboardProgress.carriedOver == progress.carriedOver)
        #expect(dashboardProgress.effectiveLimit == progress.effectiveLimit)
    }
}
