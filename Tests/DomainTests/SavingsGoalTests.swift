import Foundation
import Testing

@testable import FinanceTracker

@Suite("SavingsGoal")
struct SavingsGoalTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private func progress(
        saved: Decimal,
        target: Decimal?,
        targetDate: Date? = nil
    ) -> BudgetProgress {
        // remaining = saved → Limit groß genug wählen, spent = Limit − saved.
        let limit = max(saved, Decimal(500))
        let budget = Budget(
            name: "Urlaub",
            amount: limit,
            categoryIDs: [],
            rolloverPolicy: .accumulate,
            targetAmount: target,
            targetDate: targetDate
        )
        let spent = max(0, limit - saved)
        return BudgetProgress(
            budget: budget,
            spent: spent,
            currency: .eur,
            period: DateInterval(start: .distantPast, end: .distantFuture),
            carriedOver: 0
        )
    }

    @Test("Kein Zielbetrag → kein Sparziel-Fortschritt")
    func noTargetNoProgress() {
        let calculator = SavingsGoalCalculator()
        let goal = calculator.goalProgress(for: progress(saved: 100, target: nil))
        #expect(goal == nil)
    }

    @Test("Fortschritt = Gespartes / Ziel (geklemmt)")
    func fractionClamped() throws {
        let calculator = SavingsGoalCalculator()
        let goal = try #require(calculator.goalProgress(for: progress(saved: 250, target: 1000)))
        #expect(goal.saved == 250)
        #expect(goal.target == 1000)
        #expect(abs(goal.fraction - 0.25) < 0.0001)
        #expect(goal.shortfall == 750)
        #expect(!goal.isReached)
    }

    @Test("Übererfüllung klemmt bei 100 %")
    func overfundedClamps() throws {
        let calculator = SavingsGoalCalculator()
        let goal = try #require(calculator.goalProgress(for: progress(saved: 1200, target: 1000)))
        #expect(goal.fraction == 1)
        #expect(goal.shortfall == 0)
        #expect(goal.isReached)
    }

    @Test("Monatsrate = Fehlbetrag / volle Monate")
    func monthlyRate() throws {
        let calculator = SavingsGoalCalculator()
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        let targetDate = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        let goal = try #require(calculator.goalProgress(
            for: progress(saved: 400, target: 1000, targetDate: targetDate),
            now: now,
            calendar: calendar
        ))
        // Sep → Dez = 3 volle Monate; Fehlbetrag 600 → 200/Monat.
        #expect(goal.monthsRemaining == 3)
        #expect(goal.requiredMonthly == 200)
    }

    @Test("BudgetFormEdit übernimmt nur positive Zielbeträge")
    func formEditValidatesTarget() {
        let base = CurrencyCode.eur
        let edit = BudgetFormEdit(
            name: "Urlaub",
            systemIconName: "airplane",
            amount: 200,
            categoryIDs: [UUID()],
            rolloverAccumulate: true,
            periodPolicy: .calendarMonth(startDay: 1),
            targetAmount: 1000,
            targetDate: nil
        )
        let budget = edit.applied(to: nil, baseCurrency: base)
        #expect(budget.targetAmount == 1000)
        #expect(budget.hasSavingsGoal)

        let invalid = BudgetFormEdit(
            name: "Urlaub",
            systemIconName: "airplane",
            amount: 200,
            categoryIDs: [UUID()],
            rolloverAccumulate: true,
            periodPolicy: .calendarMonth(startDay: 1),
            targetAmount: 0,
            targetDate: nil
        )
        let cleared = invalid.applied(to: budget, baseCurrency: base)
        #expect(cleared.targetAmount == nil)
        #expect(!cleared.hasSavingsGoal)
    }

    @Test("Persistenz-Roundtrip bewahrt Sparziel")
    func persistenceRoundtrip() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let targetDate = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        let budget = Budget(
            name: "Urlaub",
            amount: 300,
            categoryIDs: [UUID()],
            rolloverPolicy: .accumulate,
            targetAmount: 1200,
            targetDate: targetDate
        )
        try await dependencies.budgetRepository.upsert([budget])
        let loaded = try #require(try await dependencies.budgetRepository.budget(id: budget.id))
        #expect(loaded.targetAmount == 1200)
        #expect(loaded.targetDate == targetDate)
        #expect(loaded.hasSavingsGoal)
    }

    @Test("Forecast reserviert Sparziel-Rest ohne Doppelzählung")
    func forecastReservesSavingsGoal() {
        let service = ForecastService()
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))!
        let periodStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let periodEnd = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let period = DateInterval(start: periodStart, end: periodEnd)
        var budget = Budget(
            name: "Urlaub",
            amount: 500,
            categoryIDs: [],
            rolloverPolicy: .accumulate,
            targetAmount: 1000
        )
        let budgetProgress = BudgetProgress(
            budget: budget,
            spent: 100,
            currency: .eur,
            period: period,
            carriedOver: 200
        )
        // remaining = 500 + 200 − 100 = 600 = Gespartes.
        #expect(budgetProgress.remaining == 600)
        let snapshot = service.forecast(
            period: period,
            transactions: [],
            budgets: [budget],
            budgetProgresses: [budgetProgress],
            commitments: [],
            baseCurrency: .eur,
            calendar: calendar,
            now: now
        )
        #expect(snapshot.remainingBudgetReservation == 600)
        #expect(snapshot.plannedSavings == 0)
    }
}
