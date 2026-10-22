
import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@Suite("BudgetRepository")
struct BudgetRepositoryTests {
    @Test("Roundtrip: Budget speichern, laden, ändern, löschen")
    func roundtrip() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        let categoryID = UUID()
        var budget = Budget(name: "Testbudget", amount: 200, categoryIDs: [categoryID])
        try await dependencies.budgetRepository.upsert([budget])

        let loaded = try await dependencies.budgetRepository.budgets()
        #expect(loaded.count == 1)
        #expect(loaded[0].amount == 200)

        budget.amount = 350
        try await dependencies.budgetRepository.upsert([budget])
        let updated = try await dependencies.budgetRepository.budgets()
        #expect(updated[0].amount == 350)

        try await dependencies.budgetRepository.delete(id: budget.id)
        #expect(try await dependencies.budgetRepository.budgets().isEmpty)
    }
}

@Suite("BudgetCalculator")
struct BudgetCalculatorTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func expense(_ amount: Decimal, categoryID: UUID, month: Int) -> Transaction {
        Transaction(
            accountID: UUID(),
            source: .openBanking,
            status: .booked,
            amount: Money(amount: -amount, currency: .eur),
            bookedAt: calendar.date(from: DateComponents(year: 2026, month: month, day: 15)),
            categoryID: categoryID
        )
    }

    @Test("Progress berechnet Spent und Fraction korrekt")
    func progressCalculation() {
        let calculator = BudgetCalculator()
        let catID = UUID()
        let budget = Budget(name: "Testbudget", amount: 200, categoryIDs: [catID])
        let transactions = [expense(150, categoryID: catID, month: 8)]

        let progress = calculator.progress(
            budgets: [budget],
            transactions: transactions,
            categories: [],
            monthInterval: DateInterval(start: .distantPast, end: .distantFuture),
            calendar: calendar
        )

        #expect(progress.count == 1)
        #expect(progress[0].spent == 150)
        #expect(!progress[0].isOverBudget)
        #expect(progress[0].fraction > 0.7 && progress[0].fraction < 0.8)
    }

    @Test("Über-Budget wird erkannt")
    func overBudget() {
        let calculator = BudgetCalculator()
        let catID = UUID()
        let budget = Budget(name: "Testbudget", amount: 100, categoryIDs: [catID])
        let transactions = [expense(150, categoryID: catID, month: 8)]

        let progress = calculator.progress(
            budgets: [budget],
            transactions: transactions,
            categories: [],
            monthInterval: DateInterval(start: .distantPast, end: .distantFuture)
        )

        #expect(progress[0].isOverBudget)
        #expect(progress[0].remaining == 0)
    }

    @Test("Deaktivierte Budgets werden ignoriert")
    func disabledIgnored() {
        let calculator = BudgetCalculator()
        let catID = UUID()
        let budget = Budget(name: "Testbudget", amount: 200, categoryIDs: [catID], enabled: false)
        let transactions = [expense(500, categoryID: catID, month: 8)]

        let progress = calculator.progress(
            budgets: [budget],
            transactions: transactions,
            categories: [],
            monthInterval: DateInterval(start: .distantPast, end: .distantFuture)
        )

        #expect(progress.isEmpty)
    }

    @Test("Reversed Transaktionen werden nicht gezählt")
    func reversedExcluded() {
        let calculator = BudgetCalculator()
        let catID = UUID()
        let budget = Budget(name: "Testbudget", amount: 200, categoryIDs: [catID])
        var txn = expense(150, categoryID: catID, month: 8)
        txn.status = .reversed

        let progress = calculator.progress(
            budgets: [budget],
            transactions: [txn],
            categories: [],
            monthInterval: DateInterval(start: .distantPast, end: .distantFuture)
        )

        #expect(progress[0].spent == 0)
    }
}
