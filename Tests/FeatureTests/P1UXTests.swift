import Foundation
import Testing

@testable import FinanceTracker

/// P1 UX (keine UI-Durchklick-Tests):
/// - Detail-Edit-Aktionen laufen über Model-Methoden (Callbacks),
/// - Bento ist der Darstellungs-Default (klassisch bleibt wählbar),
/// - Settings legt den Konten-Link als Callback offen.
@MainActor
@Suite("P1UX")
struct P1UXTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func seedTransaction(_ dependencies: AppDependencies) async throws -> Transaction {
        try await dependencies.accountRepository.upsert([
            Account(name: "P1 Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        let txn = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .demo,
            externalID: "p1-detail-1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(42), currency: .eur),
            bookedAt: Date(),
            rawDescription: "REWE",
            rawMerchantName: "REWE",
            merchantDisplayName: "REWE"
        )
        try await dependencies.transactionRepository.upsert([txn])
        return txn
    }

    // MARK: - Detail-Edit-Callbacks (Model)

    @Test("Detail: Kategorie-Picker ruft Model-Methode (changeCategory)")
    func detailCategoryEdit() async throws {
        let dependencies = try makeDependencies()
        let seeded = try await seedTransaction(dependencies)
        try await dependencies.categoryRepository.upsert([Category.groceries])
        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()

        let txn = try #require(model.transaction(withID: seeded.id))
        await model.changeCategory(txn, to: Category.groceries.id)

        #expect(model.transaction(withID: seeded.id)?.categoryID == Category.groceries.id)
        let stored = try await dependencies.transactionRepository.transaction(id: seeded.id)
        #expect(stored?.categoryID == Category.groceries.id)
    }

    @Test("Detail: Tag-Toggle ruft Model-Methode (toggleTag)")
    func detailTagToggle() async throws {
        let dependencies = try makeDependencies()
        let seeded = try await seedTransaction(dependencies)
        let tag = Tag(name: "Dienstlich", colorToken: .indigo)
        try await dependencies.tagRepository.upsert([tag])
        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()

        let txn = try #require(model.transaction(withID: seeded.id))
        await model.toggleTag(tag.id, on: txn)
        #expect(model.transaction(withID: seeded.id)?.tagIDs?.contains(tag.id) == true)

        let reloaded = try #require(model.transaction(withID: seeded.id))
        await model.toggleTag(tag.id, on: reloaded)
        #expect(model.transaction(withID: seeded.id)?.tagIDs?.contains(tag.id) != true)
    }

    @Test("Detail: Geprüft-Toggle ruft Model-Methode (toggleReviewed)")
    func detailReviewedToggle() async throws {
        let dependencies = try makeDependencies()
        let seeded = try await seedTransaction(dependencies)
        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()

        let txn = try #require(model.transaction(withID: seeded.id))
        await model.toggleReviewed(txn, reviewed: true)
        #expect(model.transaction(withID: seeded.id)?.reviewed == true)

        let reloaded = try #require(model.transaction(withID: seeded.id))
        await model.toggleReviewed(reloaded, reviewed: false)
        #expect(model.transaction(withID: seeded.id)?.reviewed == false)
    }

    @Test("Detail: Ausschließen-Toggle ruft Model-Methode (toggleExcluded)")
    func detailExcludedToggle() async throws {
        let dependencies = try makeDependencies()
        let seeded = try await seedTransaction(dependencies)
        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()

        let txn = try #require(model.transaction(withID: seeded.id))
        await model.toggleExcluded(txn, excluded: true)
        #expect(model.transaction(withID: seeded.id)?.excludedFromAnalytics == true)

        let reloaded = try #require(model.transaction(withID: seeded.id))
        await model.toggleExcluded(reloaded, excluded: false)
        #expect(model.transaction(withID: seeded.id)?.excludedFromAnalytics == false)
    }

    // MARK: - AppAppearance-Default

    @Test("Darstellungs-Default ist Bento")
    func appearanceDefaultIsBento() {
        #expect(AppAppearance.fallback == .bento)
        #expect(AppAppearance(storedValue: "").rawValue == AppAppearance.bento.rawValue)
        #expect(AppAppearance(storedValue: "unbekannt").rawValue == AppAppearance.bento.rawValue)
    }

    @Test("Alte Darstellungswerte bleiben kompatibel und werden kanonisch gespeichert")
    func legacyAppearanceValuesRemainCompatible() throws {
        #expect(AppAppearance.allCases == [.bento])
        for legacyValue in ["classic", "washi", "elegant"] {
            #expect(AppAppearance(storedValue: legacyValue) == .bento)
            let encodedLegacyValue = Data("\"\(legacyValue)\"".utf8)
            #expect(try JSONDecoder().decode(AppAppearance.self, from: encodedLegacyValue) == .bento)
        }
        #expect(try JSONEncoder().encode(AppAppearance.bento) == Data("\"bento\"".utf8))
    }

    // MARK: - Settings-Link-Callback (kein UI-Test)

    @Test("Settings legt Konten-Link als Callback offen")
    func settingsAccountsCallback() throws {
        let dependencies = try makeDependencies()
        var called = false
        let view = SettingsView(dependencies: dependencies) { called = true }
        #expect(view.onShowAccounts != nil)
        view.onShowAccounts?()
        #expect(called)

        let fallback = SettingsView(dependencies: dependencies)
        #expect(fallback.onShowAccounts == nil)
    }
}
