import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

/// WP11: Budget Currency Safety: Option A (Base-Currency-Budgets),
/// Fremdwährungen separat gemeldet, nie still gemischt.
@MainActor
@Suite("BudgetCurrencySafety")
struct BudgetCurrencySafetyTests {

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    @Test("Übersichtssummen: EUR-Budget zählt, USD-Budget bleibt separat")
    func mixedOverviewSums() async throws {
        let dependencies = try makeDependencies()
        let now = Date()
        // Captured before the budgets are created below. Existing spending in
        // the active period must still count toward a newly configured budget.
        let thisMonth = now

        let eurCategory = UUID()
        let usdCategory = UUID()

        try await dependencies.budgetRepository.upsert([
            Budget(name: "EUR-Budget", amount: 300, currency: .eur, categoryIDs: [eurCategory]),
            Budget(name: "USD-Budget", amount: 100, currency: .usd, categoryIDs: [usdCategory])
        ])

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo),
            Account(name: "Wallet", type: .checking, currency: .usd, source: .blockchain)
        ])
        let eurAccount = try #require(await dependencies.accountRepository.accounts().first(where: { $0.currency == .eur }))
        let usdAccount = try #require(await dependencies.accountRepository.accounts().first(where: { $0.currency == .usd }))

        try await dependencies.transactionRepository.upsert([
            Transaction(
                id: UUID(), accountID: eurAccount.id, source: .demo, externalID: "eur-1",
                status: .booked, kind: .purchase,
                amount: Money(amount: -120, currency: .eur),
                bookedAt: thisMonth, rawDescription: "Einkauf", rawMerchantName: "Einkauf",
                merchantDisplayName: "Einkauf", categoryID: eurCategory
            ),
            Transaction(
                id: UUID(), accountID: usdAccount.id, source: .blockchain, externalID: "usd-1",
                status: .booked, kind: .purchase,
                amount: Money(amount: -50, currency: .usd),
                bookedAt: thisMonth, rawDescription: "US Shopping", rawMerchantName: "US Shopping",
                merchantDisplayName: "US Shopping", categoryID: usdCategory
            )
        ])

        let model = BudgetsModel(dependencies: dependencies)
        await model.load()

        #expect(model.progresses.count == 2)

        // Summen nur über EUR: 300 Limit, 120 spent: USD nicht gemischt.
        #expect(model.totalLimit == 300)
        #expect(model.totalSpent == 120)
        #expect(model.foreignBudgetCurrencies == [.usd])
    }

    @Test("Nur EUR-Budgets: keine Fremdwährungs-Meldung")
    func baseOnlyNoForeignNote() async throws {
        let dependencies = try makeDependencies()
        try await dependencies.budgetRepository.upsert([
            Budget(name: "EUR", amount: 250, currency: .eur, categoryIDs: [UUID()])
        ])

        let model = BudgetsModel(dependencies: dependencies)
        await model.load()

        #expect(model.totalLimit == 250)
        #expect(model.foreignBudgetCurrencies.isEmpty)
    }

    @Test("Detail-Progress führt die echte Budget-Währung")
    func detailUsesBudgetCurrency() async throws {
        let dependencies = try makeDependencies()
        let usdCategory = UUID()

        try await dependencies.budgetRepository.upsert([
            Budget(name: "USD-Budget", amount: 100, currency: .usd, categoryIDs: [usdCategory])
        ])

        let progress = try #require(BudgetCalculator().progress(
            budgets: try await dependencies.budgetRepository.budgets(),
            transactions: [],
            categories: [],
            monthInterval: DateInterval(start: Date().addingTimeInterval(-86400), end: Date()),
            calendar: .current
        ).first)

        // Der Progress trägt die Budget-Währung, das Detail/Dashboard
        // darft niemals baseCurrency darüberschreiben.
        #expect(progress.currency == .usd)
        #expect(progress.spent == 0)
    }
}

@Suite("BudgetFormPeriodSelection")
struct BudgetFormPeriodSelectionTests {
    @Test("Gehaltszyklus ohne Einkommen ist ungültig und fällt nicht auf Kalendermonat zurück")
    func salaryCycleRequiresIncome() {
        #expect(BudgetPeriodFormSelection.policy(
            useSalaryCycle: true,
            salaryIncomeID: nil,
            availableIncomeIDs: []
        ) == nil)
    }

    @Test("Gehaltszyklus mit nicht mehr verfügbarem Einkommen ist ungültig")
    func salaryCycleRejectsUnavailableIncome() {
        #expect(BudgetPeriodFormSelection.policy(
            useSalaryCycle: true,
            salaryIncomeID: UUID(),
            availableIncomeIDs: []
        ) == nil)
    }

    @Test("Gehaltszyklus behält das ausgewählte Einkommen")
    func salaryCycleUsesSelectedIncome() {
        let incomeID = UUID()
        let policy = BudgetPeriodFormSelection.policy(
            useSalaryCycle: true,
            salaryIncomeID: incomeID,
            availableIncomeIDs: [incomeID]
        )

        #expect(policy == .salaryCycle(recurringIncomeID: incomeID))
    }

    @Test("Überschreitung wird als positive Decimal-Abweichung dargestellt")
    func overBudgetVariance() {
        let budget = Budget(name: "Lebensmittel", amount: 100, currency: .eur)
        let progress = BudgetProgress(
            budget: budget,
            spent: 125,
            currency: .eur,
            period: DateInterval(start: .distantPast, end: .distantFuture)
        )

        #expect(BudgetOverviewPresentation.variance(for: progress) == 25)
    }

    @Test("Budgetzeilen unterscheiden im Plan, gefährdet und überschritten")
    func overviewStatuses() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 16))!
        let period = DateInterval(start: start, end: end)

        let onTrack = BudgetOverviewRow(
            BudgetProgress(
                budget: Budget(name: "Im Plan", amount: 100, currency: .eur),
                spent: 20,
                currency: .eur,
                period: period
            ),
            now: now,
            calendar: calendar
        )
        let atRisk = BudgetOverviewRow(
            BudgetProgress(
                budget: Budget(name: "Gefährdet", amount: 100, currency: .eur),
                spent: 60,
                currency: .eur,
                period: period
            ),
            now: now,
            calendar: calendar
        )
        let over = BudgetOverviewRow(
            BudgetProgress(
                budget: Budget(name: "Überschritten", amount: 100, currency: .eur),
                spent: 125,
                currency: .eur,
                period: period
            ),
            now: now,
            calendar: calendar
        )

        #expect(onTrack.status == .onTrack)
        #expect(atRisk.status == .atRisk)
        #expect(over.status == .over)
        #expect(over.signedRemaining == -25)
    }

    @Test("Budgetfilter kombiniert Status und Namenssuche")
    func overviewFiltering() {
        let inPlan = BudgetOverviewRow(BudgetProgress(
            budget: Budget(name: "Lebensmittel", amount: 100, currency: .eur),
            spent: 0,
            currency: .eur,
            period: DateInterval(start: .distantPast, end: .distantFuture)
        ))
        let over = BudgetOverviewRow(BudgetProgress(
            budget: Budget(name: "Mobilität", amount: 100, currency: .eur),
            spent: 120,
            currency: .eur,
            period: DateInterval(start: .distantPast, end: .distantFuture)
        ))

        #expect(BudgetOverviewPresentation.filtered(
            [inPlan, over],
            filter: .over,
            searchText: "mobil"
        ).map(\.name) == ["Mobilität"])
        #expect(BudgetOverviewPresentation.filtered(
            [inPlan, over],
            filter: .onTrack,
            searchText: ""
        ).map(\.name) == ["Lebensmittel"])
    }
}
