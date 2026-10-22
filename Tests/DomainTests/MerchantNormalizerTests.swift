import Foundation
import Testing

@testable import FinanceTracker

@Suite("MerchantNormalizer")
struct MerchantNormalizerTests {
    private let normalizer = MerchantNormalizer()

    @Test("Bekannte Varianten werden zu kanonischen Namen")
    func canonicalMapping() throws {
        #expect(try #require(normalizer.canonicalDisplayName(from: "AMZN MKTP DE*AB123")) == "Amazon")
        #expect(try #require(normalizer.canonicalDisplayName(from: "AMAZON EU SARL")) == "Amazon")
        #expect(try #require(normalizer.canonicalDisplayName(from: "Amazon")) == "Amazon")

        #expect(try #require(normalizer.canonicalDisplayName(from: "REWE SAGT DANKE 832741 MUENCHEN")) == "REWE")
        #expect(try #require(normalizer.canonicalDisplayName(from: "REWE MARKT 72191")) == "REWE")

        #expect(try #require(normalizer.canonicalDisplayName(from: "APPLE.COM/BILL ITUNES.COM")) == "Apple")

        #expect(try #require(normalizer.canonicalDisplayName(from: "MCDONALDS 155")) == "McDonald's")
        #expect(try #require(normalizer.canonicalDisplayName(from: "SPAR MARKT 12")) == "SPAR")
        #expect(try #require(normalizer.canonicalDisplayName(from: "dm drogerie 123")) == "dm")
    }

    @Test("Kurze Händlernamen matchen keine längeren Wort-Tokens")
    func tokenBoundaries() throws {
        #expect(try #require(normalizer.canonicalDisplayName(from: "SPARKASSE MUENCHEN")) != "SPAR")
        #expect(try #require(normalizer.canonicalDisplayName(from: "ÜBERWEISUNG MIETE")) != "Uber")
        #expect(try #require(normalizer.canonicalDisplayName(from: "UBER TRIP")) == "Uber")
    }

    @Test("Unbekannte Deskriptoren: Ziffern-Tokens entfernt, Rest erhalten")
    func unknownFallback() throws {
        let result = try #require(normalizer.canonicalDisplayName(from: "HP*INSTANT GAMING 4711"))
        #expect(result.contains("INSTANT GAMING") || result.contains("Instant Gaming"))

        #expect(normalizer.canonicalDisplayName(from: "123456") != nil)
        #expect(normalizer.canonicalDisplayName(from: "") == nil)
    }

    @Test("Resolve matcht bekannte Händler über Aliases und Kanonisch-Namen")
    func resolveAgainstKnown() {
        let reweID = UUID()
        let known = [
            Merchant(id: reweID, displayName: "REWE", aliases: ["REWE SAGT DANKE"]),
            Merchant(displayName: "Amazon", aliases: ["AMZN MKTP DE"])
        ]

        let byAlias = normalizer.resolve(rawDescriptor: "REWE SAGT DANKE 998171 MUENCHEN", knownMerchants: known)
        #expect(byAlias.merchantID == reweID)
        #expect(byAlias.displayName == "REWE")
        #expect(byAlias.newMerchant == nil)
        #expect(byAlias.merchantToUpsert?.aliases.contains("REWE SAGT DANKE 998171 MUENCHEN") == true)

        let byCanonical = normalizer.resolve(rawDescriptor: "AMZN MKTP DE*99", knownMerchants: known)
        #expect(byCanonical.merchantID == known[1].id)
        #expect(byCanonical.newMerchant == nil)
    }

    @Test("Unbekannter Deskriptor erzeugt neuen Merchant-Kandidaten")
    func resolveCreatesNew() {
        let resolution = normalizer.resolve(rawDescriptor: "Totally New Shop 12", knownMerchants: [])

        #expect(resolution.merchantID != nil)
        #expect(resolution.newMerchant?.displayName != nil)
        #expect(resolution.displayName == resolution.newMerchant?.displayName)
        #expect(resolution.merchantToUpsert == resolution.newMerchant)
        #expect(resolution.newMerchant?.aliases == ["Totally New Shop 12"])
    }
}

@Suite("MerchantPipelineIntegration")
struct MerchantPipelineIntegrationTests {
    private final class BundleMarker {}

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func etherFiFixture() throws -> Data {
        let bundle = Bundle(for: BundleMarker.self)
        guard let url = bundle.url(forResource: "fixture_etherfi_cash", withExtension: "csv") else {
            throw ImportError.parsingFailed(stage: "testSetup", reason: "Fixture fehlt.")
        }
        return try Data(contentsOf: url)
    }

    @Test("Import setzt merchantID und kanonische Namen; Re-Import dupliziert Merchant nicht")
    func pipelineAssignsMerchants() async throws {
        let dependencies = try makeDependencies()
        let pipeline = ImportPipeline(
            providers: dependencies.importProviders,
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            merchantRepository: dependencies.merchantRepository,
            fallbackCurrency: .eur
        )
        let accountID = UUID()
        let fileData = try etherFiFixture()

        _ = try await pipeline.run(ImportFile(fileName: nil, data: fileData), into: accountID)
        _ = try await pipeline.run(ImportFile(fileName: nil, data: fileData), into: accountID)

        let merchants = try await dependencies.merchantRepository.merchants()
        let mcdonalds = try #require(merchants.first { $0.displayName == "McDonald's" })

        let stored = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let mcdonaldsTxns = stored.filter { $0.merchantID == mcdonalds.id }
        #expect(mcdonaldsTxns.count == 1)
        #expect(mcdonaldsTxns.allSatisfy { $0.merchantDisplayName == "McDonald's" })
        #expect(stored.allSatisfy { $0.merchantID != nil })
    }

    @Test("Korrektur erzeugt merchantID-Regel, die auf neue Buchungen desselben Händlers greift")
    func merchantIDRuleFromCorrection() async throws {
        let engine = CategoryRuleEngine()
        let merchantID = UUID()

        var firstPurchase = Transaction(
            accountID: UUID(),
            source: .etherFiCashCSV,
            status: .booked,
            amount: Money(amount: -18.3, currency: .eur),
            rawMerchantName: "MCDONALDS 155",
            merchantID: merchantID,
            merchantDisplayName: "McDonald's"
        )
        firstPurchase.categoryID = UUID()

        let rule = CategoryRule.makeFromCorrection(
            transaction: firstPurchase,
            categoryID: firstPurchase.categoryID!,
            existingRules: []
        )

        guard case .merchantIDEquals(let ruleMerchantID)? = rule?.condition else {
            Issue.record("Expected merchantIDEquals condition")
            return
        }
        #expect(ruleMerchantID == merchantID)

        var secondPurchase = Transaction(
            accountID: UUID(),
            source: .etherFiCashCSV,
            amount: Money(amount: -6.9, currency: .eur),
            rawMerchantName: "MCDONALDS 999",
            merchantID: merchantID,
            merchantDisplayName: "McDonald's"
        )

        #expect(engine.apply([try #require(rule)], to: &secondPurchase))
        #expect(secondPurchase.categoryID == firstPurchase.categoryID)
    }
}
