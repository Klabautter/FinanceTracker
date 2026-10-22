import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("SalaryCycle")
struct SalaryCycleTests {
    @Test("Gehalt-zu-Gehalt-Budget rechnet über das Income-Intervall (#97/#118)")
    func salaryCycleInterval() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 12)))
        let model = BudgetsModel(dependencies: dependencies, calendar: calendar, now: { now })
        let salaryIncomeID = UUID()

        // Income-Commitment (Gehalt, monatlich)
        let commitment = RecurringCommitment(
            id: salaryIncomeID,
            name: "Gehalt Acme GmbH",
            merchantKey: "GEHALT ACME GMBH",
            direction: .income,
            cadence: .monthly,
            amountPolicy: .fixed,
            expectedAmount: Decimal(string: "2850.00")!,
            currency: .eur,
            status: .active
        )
        try await dependencies.recurringCommitmentRepository.upsert([commitment])

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        // Income-Matches: 15. Mai und 15. Juni → Gehalt-zu-Gehalt-Intervall
        let may15 = calendar.date(from: DateComponents(year: 2026, month: 5, day: 15))!
        let jun15 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15))!

        func incomeTxn(_ date: Date) -> Transaction {
            Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: "inc-\(UUID().uuidString)",
                status: .booked,
                kind: .income,
                amount: Money(amount: Decimal(string: "2850.00")!, currency: .eur),
                bookedAt: date,
                rawDescription: "GEHALT ACME GMBH",
                rawMerchantName: "GEHALT ACME GMBH",
                merchantDisplayName: "Gehalt Acme GmbH"
            )
        }
        let targetCategoryID = UUID()
        let parentCategoryID = UUID()
        func expense(_ date: Date, _ amount: Decimal, categoryID: UUID?) -> Transaction {
            Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: "exp-\(UUID().uuidString)",
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -amount, currency: .eur),
                bookedAt: date,
                rawDescription: "Ausgabe",
                rawMerchantName: "Ausgabe",
                merchantDisplayName: "Ausgabe",
                categoryID: categoryID
            )
        }

        let splitExpense = expense(
            calendar.date(byAdding: .day, value: 3, to: jun15)!,
            Decimal(string: "777.00")!,
            categoryID: parentCategoryID
        )
        try await dependencies.transactionRepository.upsert([
            incomeTxn(may15),
            incomeTxn(jun15),
            // Innerhalb des Gehalt-zu-Gehalt-Zeitraums (15.5.–15.6.)
            expense(
                calendar.date(byAdding: .day, value: -1, to: jun15)!,
                Decimal(string: "300.00")!,
                categoryID: targetCategoryID
            ),
            splitExpense
        ])
        try await dependencies.transactionSplitRepository.upsert([
            TransactionSplitLine(
                parentTransactionID: splitExpense.id,
                amount: Decimal(string: "777.00")!,
                categoryID: targetCategoryID
            )
        ])

        // Salary-Cycle-Budget
        try await dependencies.budgetRepository.upsert([
            Budget(
                name: "Gehalt-zu-Gehalt",
                amount: Decimal(string: "1000.00")!,
                periodPolicy: .salaryCycle(recurringIncomeID: salaryIncomeID),
                categoryIDs: [targetCategoryID],
                createdAt: calendar.date(from: DateComponents(year: 2026, month: 5, day: 1))!
            )
        ])

        await model.load()

        #expect(model.progresses.count == 1)
        let progress = try #require(model.progresses.first)
        // WP6 (§44): AKTIVER Zyklus: Referenz
        // „now" liegt nach der letzten Zahlung (15.06.), also startet der
        // Zyklus dort und endet planmäßig am 15.07. Die 777 € vom 18.06.
        // liegen IM aktiven Zyklus. Die 777 € haben auf dem Parent eine
        // andere Kategorie, zählen aber über die Budget-Kategorie der Splitzeile.
        // Die 300 € vom 14.06. gehören zur VORPERIODE.
        #expect(progress.spent == Decimal(string: "777.00")!)
        #expect(progress.period.start == jun15)
        #expect(progress.period.end == calendar.date(byAdding: .month, value: 1, to: jun15)!)
    }

    @Test("Nicht auflösbarer Gehaltszyklus fällt sichtbar auf den Kalendermonat zurück")
    func unavailableSalaryCycleShowsCalendarFallback() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12)))
        let categoryID = UUID()
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.budgetRepository.upsert([
            Budget(
                name: "Gehalt ohne Historie",
                amount: 100,
                periodPolicy: .salaryCycle(recurringIncomeID: UUID()),
                categoryIDs: [categoryID],
                createdAt: calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
            )
        ])
        try await dependencies.transactionRepository.upsert([
            Transaction(
                accountID: account.id,
                source: .demo,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -35, currency: .eur),
                bookedAt: calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!,
                rawDescription: "Einkauf",
                categoryID: categoryID
            )
        ])

        let budgetsModel = BudgetsModel(dependencies: dependencies, calendar: calendar, now: { now })
        await budgetsModel.load()
        let budgetProgress = try #require(budgetsModel.progresses.first)
        #expect(budgetsModel.salaryCycleFallbackWarning?.contains("Kalendermonat") == true)
        #expect(budgetsModel.salaryCycleFallbackBudgetIDs.contains(budgetProgress.budget.id))
        #expect(budgetProgress.period.start == calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!)
        #expect(budgetProgress.period.end == calendar.date(from: DateComponents(year: 2026, month: 4, day: 1))!)
        #expect(budgetProgress.spent == 35)

        let dashboard = DashboardModel(dependencies: dependencies, calendar: calendar, now: { now })
        await dashboard.load()
        #expect(dashboard.planningDataWarning?.contains("Kalendermonat") == true)
        let dashboardProgress = try #require(dashboard.budgetProgresses.first)
        #expect(dashboardProgress.period == budgetProgress.period)
        #expect(dashboardProgress.spent == budgetProgress.spent)
    }
}
