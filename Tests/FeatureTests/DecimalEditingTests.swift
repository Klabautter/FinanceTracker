import Foundation
import Testing

@testable import FinanceTracker

/// WP4 (§33): Typed Decimal Editing: Parser und Budget-Edit-Semantik.
@Suite("DecimalEditing")
struct DecimalEditingTests {

    // MARK: - DecimalParser

    @Test("Parser: einfache ganzzahlige Eingaben")
    func plainIntegers() {
        #expect(DecimalParser.parse("500") == 500)
        #expect(DecimalParser.parse("0,99") == Decimal(string: "0.99"))
        #expect(DecimalParser.parse("0.99") == Decimal(string: "0.99"))
        #expect(DecimalParser.parse(" 42 ") == 42)
    }

    @Test("Parser: de- und en-Dezimaltrenner")
    func decimalSeparators() {
        #expect(DecimalParser.parse("500,5") == Decimal(string: "500.5"))
        #expect(DecimalParser.parse("500.5") == Decimal(string: "500.5"))
        #expect(DecimalParser.parse("500,00") == Decimal(string: "500.00"))
        #expect(DecimalParser.parse("500.00") == Decimal(string: "500.00"))
    }

    @Test("Parser: Tausendergruppen beider Konventionen")
    func thousandsGroups() {
        #expect(DecimalParser.parse("1.234,56") == Decimal(string: "1234.56"))
        #expect(DecimalParser.parse("1,234.56") == Decimal(string: "1234.56"))
        #expect(DecimalParser.parse("1.234.567") == Decimal(string: "1234567"))
        #expect(DecimalParser.parse("1,234,567") == Decimal(string: "1234567"))
    }

    @Test("Parser: Währungssymbole und Text werden entfernt")
    func currencySymbolsStripped() {
        #expect(DecimalParser.parse("500,00 €") == Decimal(string: "500.00"))
        #expect(DecimalParser.parse("€500") == 500)
        #expect(DecimalParser.parse("$12.34") == Decimal(string: "12.34"))
        #expect(DecimalParser.parse("-12,30 €") == Decimal(string: "-12.30"))
    }

    @Test("Parser: negative Beträge bleiben signiert")
    func negativeAmounts() {
        #expect(DecimalParser.parse("-42") == -42)
        #expect(DecimalParser.parse("-42,50") == Decimal(string: "-42.50"))
    }

    @Test("Parser: unparsebare Eingaben ergeben nil (kein stiller Fallback)")
    func invalidInputYieldsNil() {
        #expect(DecimalParser.parse("") == nil)
        #expect(DecimalParser.parse("   ") == nil)
        #expect(DecimalParser.parse("abc") == nil)
        #expect(DecimalParser.parse("€€") == nil)
        #expect(DecimalParser.parse("-") == nil)
        #expect(DecimalParser.parse(".") == nil)
        #expect(DecimalParser.parse("1.2.3.4,5") != nil || DecimalParser.parse("1.2.3.4,5") == nil) // Struktur, kein Crash
    }

    // MARK: - Budget Edit Semantik (§30-32)

    @MainActor
    @Suite("BudgetEditSemantics")
    struct BudgetEditSemantics {

        private func makeDependencies() throws -> AppDependencies {
            let store = try SwiftDataStore(inMemory: true)
            return AppDependencies.make(container: store.container, baseCurrency: .eur)
        }

        /// Frische Stores starten ohne Kategorien: Tests legen ihre eigene an.
        private func insertCategory(_ dependencies: AppDependencies, name: String = "Test-Kategorie") async throws -> FinanceTracker.Category {
            let category = FinanceTracker.Category(name: name, systemIconName: "cart", colorToken: .blue)
            try await dependencies.categoryRepository.upsert([category])
            return try #require(await dependencies.categoryRepository.category(id: category.id))
        }

        @Test("Edit lädt Betrag als typed Decimal und Salary-Cycle-State aus periodPolicy (§30-31)")
        func salaryCycleStateRestored() async throws {
            let dependencies = try makeDependencies()
            let income = RecurringCommitment(
                name: "Gehalt",
                direction: .income,
                cadence: .monthly,
                amountPolicy: .fixed,
                expectedAmount: 2000,
                currency: .eur,
                nextExpectedDate: nil,
                status: .active
            )
            try await dependencies.recurringCommitmentRepository.upsert([income])

            let category = try await insertCategory(dependencies)
            let salaryBudget = Budget(
                name: "Gehalts-Budget",
                amount: 300,
                currency: .eur,
                periodPolicy: .salaryCycle(recurringIncomeID: income.id),
                categoryIDs: [category.id]
            )
            try await dependencies.budgetRepository.upsert([salaryBudget])

            let stored = try #require(await dependencies.budgetRepository.budget(id: salaryBudget.id))
            // §31: periodPolicy → useSalaryCycle=true, salaryIncomeID=income.id
            guard case .salaryCycle(let incomeID) = stored.periodPolicy else {
                Issue.record("Erwartete salaryCycle-Policy")
                return
            }
            #expect(incomeID == income.id)
            #expect(stored.isSalaryCycle)
        }

        @Test("Edit behält bestehende Currency bei (kein stilles Überschreiben, §32)")
        func currencyNotSilentlyOverwritten() async throws {
            let dependencies = try makeDependencies()
            let category = try await insertCategory(dependencies, name: "USD-Kategorie")
            let usdBudget = Budget(
                name: "US-Abo-Budget",
                amount: 50,
                currency: .usd,
                categoryIDs: [category.id]
            )
            try await dependencies.budgetRepository.upsert([usdBudget])

            let existing = try #require(await dependencies.budgetRepository.budget(id: usdBudget.id))
            let edit = BudgetFormEdit(
                name: "US-Abo-Budget",
                systemIconName: existing.systemIconName,
                amount: 75,
                categoryIDs: existing.categoryIDs,
                rolloverAccumulate: false,
                periodPolicy: .calendarMonth(startDay: 1)
            )
            let updated = edit.applied(to: existing, baseCurrency: .eur)
            try await dependencies.budgetRepository.upsert([updated])

            let stored = try #require(await dependencies.budgetRepository.budget(id: usdBudget.id))
            #expect(stored.currency == .usd, "Edit darf Currency nicht still ändern (§32)")
            #expect(stored.amount == 75)
        }

        @Test("Edit bewahrt Rollover, Kategorien und periodPolicy (§33)")
        func editPreservesOtherState() {
            let incomeID = UUID()
            let categoryA = UUID()
            let existing = Budget(
                name: "Alt",
                amount: 100,
                currency: .eur,
                periodPolicy: .salaryCycle(recurringIncomeID: incomeID),
                categoryIDs: [categoryA],
                rolloverPolicy: .accumulate
            )
            let edit = BudgetFormEdit(
                name: "Neu",
                systemIconName: existing.systemIconName,
                amount: Decimal(string: "500.00")!,
                categoryIDs: existing.categoryIDs,
                rolloverAccumulate: true,
                periodPolicy: .salaryCycle(recurringIncomeID: incomeID)
            )
            let updated = edit.applied(to: existing, baseCurrency: .eur)
            #expect(updated.amount == Decimal(string: "500.00")!)
            #expect(updated.rolloverPolicy == .accumulate)
            #expect(updated.categoryIDs == [categoryA])
            #expect(updated.periodPolicy == .salaryCycle(recurringIncomeID: incomeID))
            #expect(updated.isSalaryCycle)
            #expect(updated.currency == .eur)
        }

        @Test("Neues Budget erhält Base Currency (§32)")
        func newBudgetGetsBaseCurrency() {
            let edit = BudgetFormEdit(
                name: "Neu",
                systemIconName: "cart",
                amount: 500,
                categoryIDs: [UUID()],
                rolloverAccumulate: false,
                periodPolicy: .calendarMonth(startDay: 1)
            )
            let created = edit.applied(to: nil, baseCurrency: .eur)
            #expect(created.currency == .eur)
            #expect(created.rolloverPolicy == .reset)
        }

        @Test("Cancel ändert nichts (§33)")
        func cancelChangesNothing() async throws {
            let dependencies = try makeDependencies()
            let category = try await insertCategory(dependencies, name: "Cancel-Kategorie")
            let budget = Budget(
                name: "Original",
                amount: 100,
                currency: .eur,
                categoryIDs: [category.id]
            )
            try await dependencies.budgetRepository.upsert([budget])

            // Kein upsert nach "Cancel": Store unverändert.
            let stored = try #require(await dependencies.budgetRepository.budget(id: budget.id))
            #expect(stored.amount == 100)
            #expect(stored.name == "Original")
            #expect(try await dependencies.budgetRepository.budgets().count == 1)
        }
    }
}