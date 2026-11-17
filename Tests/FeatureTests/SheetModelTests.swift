import Foundation
import Testing

@testable import FinanceTracker

/// Die aus Sheets herausgezogenen Models (Roadmap 7.2): Speichern, Laden
/// und Fehler ohne View testbar.
@MainActor
@Suite("SheetModels")
struct SheetModelTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    /// Store mit einer Ausgabenkategorie (der In-Memory-Store startet leer).
    private func makeDependenciesWithCategory() async throws -> (AppDependencies, FinanceTracker.Category) {
        let dependencies = try makeDependencies()
        let category = FinanceTracker.Category(name: "Haushalt", systemIconName: "house")
        try await dependencies.categoryRepository.upsert([category])
        return (dependencies, category)
    }

    private func transaction(merchant: String = "Stadtwerke", amount: Decimal = -60, daysAgo: Int = 3) -> Transaction {
        Transaction(
            accountID: UUID(),
            source: .manual,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!,
            rawDescription: merchant,
            merchantDisplayName: merchant
        )
    }

    @Test("Regel-Editor: Vorschau zählt Treffer, neue Regel kommt hinter bestehende Nutzerregeln")
    func ruleBuilderPreviewAndSave() async throws {
        let (dependencies, _) = try await makeDependenciesWithCategory()
        try await dependencies.transactionRepository.upsert([
            transaction(merchant: "Stadtwerke Köln"),
            transaction(merchant: "Stadtwerke Bonn"),
            transaction(merchant: "Bäckerei")
        ])
        let model = RuleBuilderModel(dependencies: dependencies)
        await model.loadCategories()
        #expect(model.loadState == .loaded)
        #expect(model.selectedCategoryID != nil)

        model.conditionValue = "stadtwerke"
        await model.loadPreview()
        #expect(model.preview?.totalCount == 2)

        let before = try await dependencies.ruleRepository.rules().filter { $0.origin == .user }.map(\.priority).max() ?? 100
        #expect(await model.save())
        let saved = try #require(try await dependencies.ruleRepository.rules().first { $0.condition == .merchantContains("stadtwerke") })
        #expect(saved.priority > before)
        #expect(saved.origin == .user)
    }

    @Test("Regel-Editor: ohne Wert kein Speichern")
    func ruleBuilderRejectsEmptyValue() async throws {
        let model = RuleBuilderModel(dependencies: try makeDependencies())
        await model.loadCategories()
        model.conditionValue = "   "
        #expect(model.canSave == false)
        #expect(await model.save() == false)
    }

    @Test("Budget-Formular: ungültiger Betrag ist ein Eingabefehler, kein Ladefehler")
    func addBudgetValidation() async throws {
        let (dependencies, _) = try await makeDependenciesWithCategory()
        let model = AddBudgetModel(dependencies: dependencies, editing: nil)
        await model.load()
        #expect(model.loadState == .loaded)
        let category = try #require(model.leafCategories.first)

        model.name = "Lebensmittel"
        model.toggleCategory(category.id)
        model.amount = 0
        #expect(await model.save() == false)
        #expect(model.actionError != nil)
        #expect(model.loadState == .loaded)

        model.amount = 400
        #expect(await model.save())
        let budget = try #require(try await dependencies.budgetRepository.budgets().first)
        #expect(budget.amount == 400)
        #expect(budget.categoryIDs == [category.id])
    }

    @Test("Budget-Formular: Gehaltszyklus ohne Einkommen wird nicht still zum Kalendermonat")
    func addBudgetSalaryCycleNeedsIncome() async throws {
        let (dependencies, _) = try await makeDependenciesWithCategory()
        let model = AddBudgetModel(dependencies: dependencies, editing: nil)
        await model.load()
        model.name = "Alltag"
        model.toggleCategory(try #require(model.leafCategories.first).id)
        model.amount = 300
        model.useSalaryCycle = true
        #expect(model.canSave == false)
        #expect(await model.save() == false)
        #expect(try await dependencies.budgetRepository.budgets().isEmpty)
    }

    @Test("Konto-Editor: speichert ein neues Konto")
    func accountEditorSaves() async throws {
        let dependencies = try makeDependencies()
        var draft = AccountEditorDraft(editing: nil, transactionCount: 0, baseCurrency: .eur)
        draft.name = "Geldbeutel"
        let model = AccountEditorModel(dependencies: dependencies, draft: draft)
        #expect(await model.save())
        #expect(try await dependencies.accountRepository.accounts().contains { $0.name == "Geldbeutel" })
    }

    @Test("Zahlungsplan: Zuordnen lädt Zahlungen neu, ohne ungespeicherte Eingaben zu überschreiben")
    func fixkostenAssignKeepsEdits() async throws {
        let dependencies = try makeDependencies()
        let commitment = RecurringCommitment(
            name: "Strom", merchantKey: "STROMANBIETER", direction: .expense, cadence: .monthly,
            amountPolicy: .fixed, expectedAmount: 60, currency: .eur
        )
        try await dependencies.recurringCommitmentRepository.upsert([commitment])
        let txn = transaction(merchant: "Irgendwas", amount: -61)
        try await dependencies.transactionRepository.upsert([txn])

        let model = FixkostenDetailModel(commitment: commitment, dependencies: dependencies)
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.unassignedTransactions.contains { $0.id == txn.id })

        model.name = "Strom (neu)"
        await model.assign(txn)
        #expect(model.actionError == nil)
        #expect(model.paidTransactions.contains { $0.id == txn.id })
        #expect(model.explicitlyAssignedIDs.contains(txn.id))
        #expect(model.name == "Strom (neu)")

        await model.unassign(transactionID: txn.id)
        #expect(!model.explicitlyAssignedIDs.contains(txn.id))
        #expect(try await dependencies.recurringCommitmentRepository.occurrences(commitmentID: commitment.id).isEmpty)
    }

    @Test("Belege: ablegen, auflisten, löschen; Datei liegt im Belegordner")
    func attachmentsRoundTrip() async throws {
        let dependencies = try makeDependencies()
        let txn = transaction()
        try await dependencies.transactionRepository.upsert([txn])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentModel-\(UUID().uuidString)")
        let base = root.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Rechnung.pdf")
        try Data("%PDF-1.4 test".utf8).write(to: source)

        let model = TransactionAttachmentModel(transactionID: txn.id, dependencies: dependencies, baseDirectory: base)
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.attachments.isEmpty)

        await model.importFile(source)
        #expect(model.actionError == nil)
        let attachment = try #require(model.attachments.first)
        #expect(attachment.fileName == "Rechnung.pdf")
        #expect(attachment.mimeType == "application/pdf")
        let stored = try #require(model.existingFileURL(for: attachment))
        #expect(stored.path.hasPrefix(base.path))

        await model.delete(attachment)
        #expect(model.attachments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stored.path))
    }

    @Test("Belege: nur PDF und Bilder werden beim Ziehen angenommen")
    func attachmentDropFilter() {
        #expect(TransactionAttachmentModel.isSupportedFile(URL(fileURLWithPath: "/tmp/a.PDF")))
        #expect(TransactionAttachmentModel.isSupportedFile(URL(fileURLWithPath: "/tmp/a.heic")))
        #expect(!TransactionAttachmentModel.isSupportedFile(URL(fileURLWithPath: "/tmp/a.zip")))
        #expect(!TransactionAttachmentModel.isSupportedFile(URL(string: "https://example.com/a.pdf")!))
    }
}
