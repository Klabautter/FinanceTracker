import Foundation
import Testing

@testable import FinanceTracker

/// Vorschläge aus dem Händlernamen: Das Sprachmodell ist hier ein
/// Stellvertreter mit festen Antworten.
@MainActor
@Suite("ReviewQueueAdvice")
struct ReviewQueueAdviceTests {
    private actor StubAdvisor: MerchantCategoryAdvisor {
        nonisolated let isAvailable: Bool
        private let answers: [String: FinanceTracker.Category.ID]
        private(set) var askedNames: [String] = []

        init(isAvailable: Bool = true, answers: [String: FinanceTracker.Category.ID]) {
            self.isAvailable = isAvailable
            self.answers = answers
        }

        private var newProposals: [String: (String, FinanceTracker.Category.ID?)] = [:]

        func proposeNew(_ merchant: String, name: String, parentID: FinanceTracker.Category.ID?) {
            newProposals[merchant] = (name, parentID)
        }

        func adviseCategory(
            merchantName: String,
            isIncome: Bool,
            candidates: [FinanceTracker.Category],
            parents: [FinanceTracker.Category]
        ) async -> MerchantCategoryAdvice? {
            askedNames.append(merchantName)
            if let proposal = newProposals[merchantName] {
                return .newCategory(name: proposal.0, parentID: proposal.1)
            }
            guard let answer = answers[merchantName], candidates.contains(where: { $0.id == answer }) else {
                return nil
            }
            return .existing(answer)
        }
    }

    private func makeDependencies(advisor: any MerchantCategoryAdvisor) throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur, categoryAdvisor: advisor)
    }

    private func seed(_ dependencies: AppDependencies, merchants: [(String, Decimal)]) async throws -> [Transaction] {
        try await dependencies.categoryRepository.upsert(FinanceTracker.Category.defaultCatalog())
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let transactions = merchants.map { name, amount in
            Transaction(
                accountID: account.id,
                source: .genericCSV,
                kind: amount < 0 ? .purchase : .income,
                amount: Money(amount: amount, currency: .eur),
                bookedAt: Date(),
                rawDescription: name,
                rawMerchantName: name,
                merchantDisplayName: name
            )
        }
        try await dependencies.transactionRepository.upsert(transactions)
        return transactions
    }

    private func waitUntilAdvised(_ model: ReviewQueueModel) async {
        for _ in 0..<200 where model.isAdvising {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Modell-Vorschläge erscheinen als Vorschlag, nichts wird ohne Bestätigung zugeordnet")
    func adviceBecomesSuggestion() async throws {
        let advisor = StubAdvisor(answers: ["Radhaus Musterstadt": FinanceTracker.Category.shopping.id])
        let dependencies = try makeDependencies(advisor: advisor)
        let seeded = try await seed(dependencies, merchants: [
            ("Radhaus Musterstadt", -120), ("Radhaus Musterstadt", -15), ("Unbekannt XY", -5), ("Gutschrift Irgendwas", 20)
        ])

        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()
        await waitUntilAdvised(model)

        #expect(model.suggestions[seeded[0].id]
            == CategorySuggestion(categoryID: FinanceTracker.Category.shopping.id, supportCount: 0, origin: .deviceModel))
        #expect(model.suggestions[seeded[1].id]?.categoryID == FinanceTracker.Category.shopping.id)
        #expect(model.suggestions[seeded[2].id] == nil)
        #expect(model.suggestions[seeded[3].id] == nil)

        // Jeder Händler wird einmal gefragt, Zahlungseingänge gar nicht.
        #expect(await advisor.askedNames.sorted() == ["Radhaus Musterstadt", "Unbekannt XY"])

        // Modell-Vorschläge gehören nicht in die Sammel-Übernahme.
        #expect(model.bulkAcceptableEntries.isEmpty)
        await model.acceptAllSuggestions()

        // Gespeichert ist weiterhin nichts.
        let stored = try await dependencies.transactionRepository.transaction(id: seeded[0].id)
        #expect(stored?.categoryID == nil)

        // Erneutes Laden fragt bekannte Namen nicht noch einmal.
        await model.load()
        await waitUntilAdvised(model)
        #expect(await advisor.askedNames.count == 2)
    }

    @Test("Bestätigen übernimmt den Modell-Vorschlag wie jeden anderen")
    func acceptingAdvice() async throws {
        let advisor = StubAdvisor(answers: ["Radhaus Musterstadt": FinanceTracker.Category.shopping.id])
        let dependencies = try makeDependencies(advisor: advisor)
        let seeded = try await seed(dependencies, merchants: [("Radhaus Musterstadt", -120)])

        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()
        await waitUntilAdvised(model)
        let entry = try #require(model.suggestedCategorizeEntries.first)
        await model.acceptSuggestion(entry)

        let stored = try await dependencies.transactionRepository.transaction(id: seeded[0].id)
        #expect(stored?.categoryID == FinanceTracker.Category.shopping.id)
    }

    @Test("Ohne verfügbares Modell bleibt die Prüfliste unverändert nutzbar")
    func unavailableModelIsSkipped() async throws {
        let advisor = StubAdvisor(isAvailable: false, answers: ["Radhaus Musterstadt": FinanceTracker.Category.shopping.id])
        let dependencies = try makeDependencies(advisor: advisor)
        _ = try await seed(dependencies, merchants: [("Radhaus Musterstadt", -120)])

        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()
        #expect(!model.isAdvising)
        #expect(model.suggestions.isEmpty)
        #expect(await advisor.askedNames.isEmpty)
    }

    @Test("Passt keine Kategorie, schlägt das Modell eine neue vor; gleiche Vorschläge werden zusammengefasst")
    func newCategoryProposals() async throws {
        let advisor = StubAdvisor(answers: [:])
        await advisor.proposeNew("Techniker Krankenkasse", name: "Versicherungen", parentID: nil)
        await advisor.proposeNew("HUK Coburg", name: "Versicherung", parentID: nil)
        let dependencies = try makeDependencies(advisor: advisor)
        let seeded = try await seed(dependencies, merchants: [("Techniker Krankenkasse", -120), ("HUK Coburg", -45)])

        let model = ReviewQueueModel(dependencies: dependencies)
        await model.load()
        await waitUntilAdvised(model)

        let entries = model.entries(for: .categorize)
        let proposals = entries.compactMap { model.newCategoryProposal(for: $0) }
        #expect(proposals.count == 2)
        #expect(Set(proposals.map(\.name)).count == 1)
        // Nichts wird ohne Bestätigung angelegt.
        let categories = try await dependencies.categoryRepository.categories()
        #expect(!categories.contains { $0.name == "Versicherungen" })

        // Nach dem Anlegen für einen Händler wird es für den anderen ein normaler Vorschlag.
        let tk = try #require(entries.first { $0.transaction.id == seeded[0].id })
        model.requestCategoryCreation(for: tk, suggestedName: "Versicherungen")
        let request = try #require(model.categoryCreationRequest)
        #expect(request.suggestedName == "Versicherungen")
        let created = FinanceTracker.Category(name: "Versicherungen", systemIconName: "shield", colorToken: .teal)
        try await dependencies.categoryRepository.upsert([created])
        await model.categoryCreated(created, for: request)
        await waitUntilAdvised(model)

        let huk = try #require(model.entries(for: .categorize).first { $0.transaction.id == seeded[1].id })
        #expect(model.newCategoryProposal(for: huk) == nil)
        #expect(model.suggestions[huk.id]?.categoryID == created.id)
    }
}
