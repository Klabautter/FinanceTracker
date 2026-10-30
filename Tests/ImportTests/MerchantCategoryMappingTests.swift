import Foundation
import Testing

@testable import FinanceTracker

@Suite("Kartenexport: Branchenangabe → Kategorie")
struct MerchantCategoryMappingTests {
    private final class BundleMarker {}

    private func fixtureFile() throws -> ImportFile {
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: "fixture_card_cashback", withExtension: "csv"))
        return ImportFile(fileName: "fixture_card_cashback.csv", data: try Data(contentsOf: url))
    }

    @Test("Bekannte Branchen werden zugeordnet, auch mit MCC-Präfix")
    func knownIndustries() {
        #expect(MerchantCategoryMapper.categoryID(for: "Grocery Stores and Supermarkets") == Category.groceries.id)
        #expect(MerchantCategoryMapper.categoryID(for: "Miscellaneous Food Stores-Convenience Stores and Specialty Markets") == Category.groceries.id)
        #expect(MerchantCategoryMapper.categoryID(for: "5814 - Quick Payment Service-Fast Food Restaurants") == Category.restaurants.id)
        #expect(MerchantCategoryMapper.categoryID(for: "Drug Stores and Pharmacies") == Category.health.id)
        #expect(MerchantCategoryMapper.categoryID(for: "Bicycle Shop-Sales and Services") == Category.shopping.id)
        #expect(MerchantCategoryMapper.categoryID(for: "Digital Goods: Games") == Category.shopping.id)
        #expect(MerchantCategoryMapper.categoryID(for: "Family Clothing Stores") == Category.shopping.id)
        #expect(MerchantCategoryMapper.categoryID(for: "Electronics Stores") == Category.shopping.id)
    }

    @Test("Unbekannte oder fehlende Branche ergibt keinen Vorschlag, kein Sonstiges-Fallback")
    func unknownIndustries() {
        #expect(MerchantCategoryMapper.categoryID(for: nil) == nil)
        #expect(MerchantCategoryMapper.categoryID(for: "   ") == nil)
        #expect(MerchantCategoryMapper.categoryID(for: "Government Services-Not Elsewhere Classified") == nil)
    }

    @Test("Import ordnet nach Branche zu; eigene Regeln haben Vorrang")
    func pipelineUsesSuggestionAfterRules() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let provider = GenericCSVProvider(fallbackCurrency: .eur)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur, importProviders: [provider])
        try await dependencies.categoryRepository.upsert(Category.defaultCatalog())
        // Eigene Regel: der Fahrradladen gehört für diesen Nutzer zu „Reisen".
        try await dependencies.ruleRepository.upsert([
            CategoryRule(priority: 1, condition: .merchantContains("OPTIMIZE"), categoryID: Category.travel.id, origin: .user)
        ])
        let pipeline = ImportPipeline(
            providers: [provider],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            merchantRepository: dependencies.merchantRepository,
            categoryRepository: dependencies.categoryRepository,
            fallbackCurrency: .eur
        )
        _ = try await pipeline.run(try fixtureFile(), into: UUID())

        let all = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        func category(_ needle: String) -> UUID? {
            all.first { ($0.rawDescription ?? "").localizedCaseInsensitiveContains(needle) }?.categoryID
        }
        #expect(category("OPTIMIZE") == Category.travel.id)          // eigene Regel schlägt Branche
        #expect(category("INSTANT GAMING") == Category.shopping.id)  // nur über die Branche
        #expect(category("Shop Apotheke") == Category.health.id)
        #expect(category("SPAR") == Category.groceries.id)
        #expect(category("MCDONALDS") == Category.restaurants.id)
    }
}
