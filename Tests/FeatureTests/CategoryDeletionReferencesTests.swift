import Foundation
import Testing

@testable import FinanceTracker

/// Eine gelöschte Kategorie darf nirgends als Verweis zurückbleiben: Budgets,
/// Splitzeilen und Fixkosten zeigten sonst ins Leere, und jedes danach
/// erstellte Backup scheiterte bei der Wiederherstellung an der
/// Verweisprüfung.
@MainActor
@Suite("CategoryDeletionReferences")
struct CategoryDeletionReferencesTests {
    private struct Fixture {
        let dependencies: AppDependencies
        let model: CategoriesModel
        let doomed: FinanceTracker.Category
        let other: FinanceTracker.Category
        let splitLineID: UUID
        let commitmentID: UUID
        let budgetID: UUID
    }

    private func makeFixture(budgetCategories: (FinanceTracker.Category, FinanceTracker.Category) -> Set<UUID>) async throws -> Fixture {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let doomed = FinanceTracker.Category(name: "Streaming", systemIconName: "tv")
        let other = FinanceTracker.Category(name: "Freizeit", systemIconName: "figure.walk")
        try await dependencies.categoryRepository.upsert([doomed, other])
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])

        let plain = Transaction(accountID: account.id, source: .manual, status: .booked, kind: .purchase,
            amount: Money(amount: -12, currency: .eur), bookedAt: Date(), rawDescription: "Abo", categoryID: doomed.id)
        let parent = Transaction(accountID: account.id, source: .manual, status: .booked, kind: .purchase,
            amount: Money(amount: -30, currency: .eur), bookedAt: Date(), rawDescription: "Einkauf")
        try await dependencies.transactionRepository.upsert([plain, parent])
        let doomedLine = TransactionSplitLine(parentTransactionID: parent.id, amount: 10, categoryID: doomed.id)
        try await dependencies.transactionSplitRepository.upsert([
            doomedLine,
            TransactionSplitLine(parentTransactionID: parent.id, amount: 20, categoryID: other.id)
        ])
        let commitment = RecurringCommitment(
            name: "Streaming-Abo",
            merchantKey: "STREAMING",
            direction: .expense,
            cadence: .monthly,
            amountPolicy: .fixed,
            expectedAmount: 12,
            currency: .eur,
            categoryID: doomed.id,
            status: .active
        )
        try await dependencies.recurringCommitmentRepository.upsert([commitment])
        let budget = Budget(name: "Unterhaltung", amount: 50, categoryIDs: budgetCategories(doomed, other))
        try await dependencies.budgetRepository.upsert([budget])
        try await dependencies.ruleRepository.upsert([
            CategoryRule(priority: 1, condition: .merchantContains("STREAMING"), categoryID: doomed.id)
        ])

        let model = CategoriesModel(dependencies: dependencies)
        await model.load()
        return Fixture(
            dependencies: dependencies, model: model, doomed: doomed, other: other,
            splitLineID: doomedLine.id, commitmentID: commitment.id, budgetID: budget.id
        )
    }

    private func splitLineCategory(_ fixture: Fixture) async throws -> UUID? {
        try #require(
            try await fixture.dependencies.transactionSplitRepository.allSplitLines().first { $0.id == fixture.splitLineID }
        ).categoryID
    }

    @Test("Löschen ohne Ziel räumt Splits, Fixkosten und Budgets auf; das Backup bleibt wiederherstellbar")
    func deleteWithoutTargetClearsReferences() async throws {
        let fixture = try await makeFixture { [$0.id, $1.id] }

        await fixture.model.delete(fixture.doomed, reassignTo: nil)

        #expect(fixture.model.errorMessage == nil)
        #expect(try await fixture.dependencies.categoryRepository.category(id: fixture.doomed.id) == nil)
        #expect(try await splitLineCategory(fixture) == nil)
        #expect(try await fixture.dependencies.recurringCommitmentRepository.commitment(id: fixture.commitmentID)?.categoryID == nil)
        #expect(try await fixture.dependencies.budgetRepository.budget(id: fixture.budgetID)?.categoryIDs == [fixture.other.id])
        #expect(try await fixture.dependencies.ruleRepository.rules().isEmpty)

        let backup = try await BackupService.makeBackup(dependencies: fixture.dependencies)
        #expect(throws: Never.self) { try BackupRestoreService.validate(backup) }
    }

    @Test("Löschen mit Zielkategorie hängt Splits, Fixkosten und Budgets um")
    func deleteWithTargetReassignsReferences() async throws {
        let fixture = try await makeFixture { doomed, _ in [doomed.id] }

        await fixture.model.delete(fixture.doomed, reassignTo: fixture.other.id)

        #expect(fixture.model.errorMessage == nil)
        #expect(try await splitLineCategory(fixture) == fixture.other.id)
        #expect(try await fixture.dependencies.recurringCommitmentRepository.commitment(id: fixture.commitmentID)?.categoryID == fixture.other.id)
        #expect(try await fixture.dependencies.budgetRepository.budget(id: fixture.budgetID)?.categoryIDs == [fixture.other.id])

        let backup = try await BackupService.makeBackup(dependencies: fixture.dependencies)
        #expect(throws: Never.self) { try BackupRestoreService.validate(backup) }
    }

    @Test("Einzige Kategorie eines Budgets: Löschen ohne Ziel wird mit Hinweis abgelehnt")
    func deleteOnlyBudgetCategoryIsRejected() async throws {
        let fixture = try await makeFixture { doomed, _ in [doomed.id] }

        await fixture.model.delete(fixture.doomed, reassignTo: nil)

        // Ein Budget ohne Kategorie hätte eine andere Bedeutung (zählt nichts
        // oder, im Gehaltszyklus, alles): nichts wird still umgedeutet.
        let message = try #require(fixture.model.deletionBlockedMessage)
        #expect(message.contains("Unterhaltung"))
        #expect(fixture.model.errorMessage == nil)
        #expect(try await fixture.dependencies.categoryRepository.category(id: fixture.doomed.id) != nil)
        #expect(try await fixture.dependencies.budgetRepository.budget(id: fixture.budgetID)?.categoryIDs == [fixture.doomed.id])
        #expect(try await splitLineCategory(fixture) == fixture.doomed.id)
        #expect(try await fixture.dependencies.recurringCommitmentRepository.commitment(id: fixture.commitmentID)?.categoryID == fixture.doomed.id)
        #expect(try await fixture.dependencies.ruleRepository.rules().count == 1)
    }
}
