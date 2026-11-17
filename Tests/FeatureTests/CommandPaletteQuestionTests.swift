#if DEBUG
import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("CommandPaletteQuestion")
struct CommandPaletteQuestionTests {
    @Test("Frage in der Palette liefert eine Antwortzeile, Suchbegriff nicht")
    func answersQuestions() async throws {
        let dependencies = PreviewDependencies.dependencies()
        let defaults = UserDefaults(suiteName: "palette-\(UUID().uuidString)")!
        defaults.set(false, forKey: PrivacyPresentationState.defaultsKey)
        let model = CommandPaletteModel(dependencies: dependencies, privacyState: PrivacyPresentationState(defaults: defaults))
        await model.loadStaticEntries()

        #expect(await model.answer(question: "REWE") == nil)
        let answer = try #require(await model.answer(question: "Wie viel habe ich diesen Monat für Lebensmittel ausgegeben?"))
        #expect(answer.text.contains("Lebensmittel"))
        #expect(answer.text.contains("ausgegeben"))
        #expect(answer.text.contains("Buchungen"))
        // Die Buchungen hinter der Summe stehen dabei, höchstens acht.
        #expect(!answer.entries.isEmpty)
        #expect(answer.entries.count <= CommandPaletteModel.QuestionAnswer.shownLimit)
        #expect(answer.entries.count + answer.hiddenCount == answer.transactionCount)
        #expect(answer.entries.allSatisfy { if case .transaction = $0.kind { true } else { false } })
    }

    private struct FixedInterpreter: FinanceQuestionInterpreter {
        let answer: String?
        var isAvailable: Bool { true }
        func categoryName(inQuestion question: String, categoryNames: [String]) async -> String? {
            answer.flatMap { categoryNames.contains($0) ? $0 : nil }
        }
    }

    private func makeModel(interpreter: (any FinanceQuestionInterpreter)?) async throws -> (CommandPaletteModel, AppDependencies) {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(
            container: store.container, baseCurrency: .eur, questionInterpreter: interpreter
        )
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        let defaults = UserDefaults(suiteName: "palette-\(UUID().uuidString)")!
        defaults.set(false, forKey: PrivacyPresentationState.defaultsKey)
        let model = CommandPaletteModel(dependencies: dependencies, privacyState: PrivacyPresentationState(defaults: defaults))
        return (model, dependencies)
    }

    private let now = Date(timeIntervalSince1970: 1_793_000_000) // 26.10.2026

    private func purchase(_ amount: Decimal, category: FinanceTracker.Category?, accountID: UUID) -> Transaction {
        var txn = Transaction(
            accountID: accountID, source: .manual, externalID: UUID().uuidString, status: .booked, kind: .purchase,
            amount: Money(amount: amount, currency: .eur), bookedAt: now.addingTimeInterval(-86_400),
            rawDescription: "Trattoria", rawMerchantName: "Trattoria", merchantDisplayName: "Trattoria"
        )
        txn.categoryID = category?.id
        return txn
    }

    @Test("Freie Formulierung: das Sprachmodell des Geräts ordnet sie einer vorhandenen Kategorie zu")
    func interpreterMapsFreeWording() async throws {
        let (model, dependencies) = try await makeModel(interpreter: FixedInterpreter(answer: Category.restaurants.name))
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.transactionRepository.upsert([
            purchase(-40, category: .restaurants, accountID: account.id),
            purchase(-90, category: .groceries, accountID: account.id)
        ])
        await model.loadStaticEntries()

        let answer = try #require(await model.answer(question: "Wie viel für Pizza und Sushi diesen Monat?", now: now))
        #expect(answer.text.contains(Category.restaurants.name))
        #expect(answer.transactionCount == 1)

        // Ohne Modell bleibt es bei den Regeln: keine Kategorie, alle Ausgaben.
        let (plain, plainDependencies) = try await makeModel(interpreter: nil)
        try await plainDependencies.accountRepository.upsert([account])
        try await plainDependencies.transactionRepository.upsert([
            purchase(-40, category: .restaurants, accountID: account.id),
            purchase(-90, category: .groceries, accountID: account.id)
        ])
        await plain.loadStaticEntries()
        let plainAnswer = try #require(await plain.answer(question: "Wie viel für Pizza und Sushi diesen Monat?", now: now))
        #expect(plainAnswer.transactionCount == 2)
    }

    @Test("Aufgeteilte Buchung zählt in der Antwort nur mit der gefragten Position")
    func splitTransactionsCountByLine() async throws {
        let (model, dependencies) = try await makeModel(interpreter: nil)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        // 100 € als Lebensmittel gebucht, aufgeteilt in 70 Lebensmittel + 30 Restaurants.
        let split = purchase(-100, category: .groceries, accountID: account.id)
        try await dependencies.transactionRepository.upsert([split])
        try await dependencies.transactionSplitRepository.upsert([
            TransactionSplitLine(parentTransactionID: split.id, amount: 70, categoryID: Category.groceries.id),
            TransactionSplitLine(parentTransactionID: split.id, amount: 30, categoryID: Category.restaurants.id)
        ])
        await model.loadStaticEntries()

        let restaurants = try #require(await model.answer(question: "Wie viel für Restaurants diesen Monat?", now: now))
        #expect(restaurants.text.contains("30"))
        #expect(!restaurants.text.contains("100"))
        #expect(restaurants.transactionCount == 1)
        let groceries = try #require(await model.answer(question: "Wie viel für Lebensmittel diesen Monat?", now: now))
        #expect(groceries.text.contains("70"))
    }
}
#endif
