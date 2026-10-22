import Foundation
import Testing

@testable import FinanceTracker

@Suite("MetaMaskCardCSVProvider")
struct MetaMaskCardCSVProviderTests {
    private final class BundleMarker {}

    private func fixtureData(_ name: String, ext: String = "csv") throws -> Data {
        let bundle = Bundle(for: BundleMarker.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw ImportError.parsingFailed(stage: "testSetup", reason: "Fixture \(name).\(ext) nicht gefunden.")
        }
        return try Data(contentsOf: url)
    }

    private var provider: MetaMaskCardCSVProvider { MetaMaskCardCSVProvider(fallbackCurrency: .eur) }

    private func makeDependenciesForE2E() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(
            container: store.container,
            baseCurrency: .eur,
            importProviders: [provider]
        )
    }

    private func makePipeline(_ dependencies: AppDependencies) -> ImportPipeline {
        ImportPipeline(
            providers: dependencies.importProviders,
            transactionRepository: dependencies.transactionRepository,
            fallbackCurrency: .eur
        )
    }

    @Test("Erkennt MetaMask-Export an Fiat/Crypto/Reference-Signatur, fremde CSVs nicht")
    func canHandleDetection() async throws {
        let file = try ImportFile(fileName: nil, data: fixtureData("fixture_metamask_card"))
        #expect(try await provider.canHandle(file) == true)

        let generic = try ImportFile(fileName: nil, data: fixtureData("fixture_generic_bank_en"))
        #expect(try await provider.canHandle(generic) == false)

        let etherfi = try ImportFile(fileName: nil, data: fixtureData("fixture_etherfi_cash"))
        #expect(try await provider.canHandle(etherfi) == false)

        let nonsense = ImportFile(fileName: nil, data: Data("a,b\n1,2\n".utf8))
        #expect(try await provider.canHandle(nonsense) == false)
    }

    @Test("PURCHASE wird negativ normalisiert, REFUND/CASHBACK positiv, FEE negativ")
    func signSemantics() {
        let eur = CurrencyCode.eur

        let (purchaseKind, purchaseMoney) = MetaMaskCardCSVProvider.normalizeSemantics(
            type: "purchase",
            amount: Money(amount: Decimal(string: "18.30")!, currency: eur)
        )
        #expect(purchaseKind == .purchase)
        #expect(purchaseMoney.amount == Decimal(string: "-18.30")!)

        let (refundKind, refundMoney) = MetaMaskCardCSVProvider.normalizeSemantics(
            type: "refund",
            amount: Money(amount: Decimal(string: "16.49")!, currency: eur)
        )
        #expect(refundKind == .refund)
        #expect(refundMoney.amount == Decimal(string: "16.49")!)

        let (cashbackKind, _) = MetaMaskCardCSVProvider.normalizeSemantics(
            type: "cashback",
            amount: Money(amount: Decimal(string: "2.50")!, currency: eur)
        )
        #expect(cashbackKind == .cashback)

        let (feeKind, feeMoney) = MetaMaskCardCSVProvider.normalizeSemantics(
            type: "fee",
            amount: Money(amount: Decimal(string: "1.00")!, currency: eur)
        )
        #expect(feeKind == .fee)
        #expect(feeMoney.amount == Decimal(string: "-1.00")!)

        // Negativ exportierte Purchase wird ebenfalls zu negativer Ausgabe
        let (_, negativeExportMoney) = MetaMaskCardCSVProvider.normalizeSemantics(
            type: "purchase",
            amount: Money(amount: Decimal(string: "-5.00")!, currency: eur)
        )
        #expect(negativeExportMoney.amount == Decimal(string: "-5.00")!)
    }

    @Test("Fixture-Parse: Status-Mapping, Crypto-Metadaten, External-ID, Invalid-Rows")
    func parsesFixture() async throws {
        let file = try ImportFile(fileName: nil, data: fixtureData("fixture_metamask_card"))
        let result = try await provider.parse(file)

        // 9 Datenzeilen, 1 invalid (Betrag „NOT_A_NUMBER")
        #expect(result.totalRows == 9)
        #expect(result.transactions.count == 8)
        #expect(result.issues.count == 1)

        let mcdonalds = try #require(
            result.transactions.first(where: { $0.externalID == "mm-1001" })
        )
        #expect(mcdonalds.kind == .purchase)
        #expect(mcdonalds.amount.amount == Decimal(string: "-18.30")!)
        #expect(mcdonalds.amount.currency == .eur)
        #expect(mcdonalds.cryptoAsset == "USDC")
        #expect(mcdonalds.cryptoAmount == Decimal(string: "18.31")!)
        #expect(mcdonalds.status == .booked)

        let pending = try #require(
            result.transactions.first(where: { $0.externalID == "mm-1004" })
        )
        #expect(pending.status == .pending)
        #expect(pending.bookedAt == nil)
        #expect(pending.authorizedAt != nil)

        let declined = try #require(
            result.transactions.first(where: { $0.externalID == "mm-1005" })
        )
        #expect(declined.status == .cancelled)

        let fee = try #require(
            result.transactions.first(where: { $0.externalID == "mm-1006" })
        )
        #expect(fee.kind == .fee)

        let issueRowIndexes = result.issues.map(\.rowIndex)
        #expect(issueRowIndexes == [8]) // NOT_A_NUMBER
    }

    @Test("Import-Pipeline E2E: Import, Dedup bei Re-Import, Analytics wirksam")
    func pipelineE2E() async throws {
        let dependencies = try makeDependenciesForE2E()
        let pipeline = makePipeline(dependencies)
        let file = try ImportFile(fileName: nil, data: fixtureData("fixture_metamask_card"))

        try await dependencies.accountRepository.upsert([
            Account(name: "MetaMask Card", type: .cryptoCard, currency: .eur, source: .manual)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        // AddDataSource-Vorschlagsname über Detection
        let detected = try await pipeline.detectProvider(for: file)
        #expect(detected?.identifier == MetaMaskCardCSVProvider.providerIdentifier)

        let firstRun = try await pipeline.run(file, into: account.id)
        #expect(firstRun.importedCount == 8)
        #expect(firstRun.duplicateCount == 0)
        #expect(firstRun.failedCount == 1) // 1 invalid row (Betrag)

        // Re-Import: Dedup, kein zweiter Satz
        let secondRun = try await pipeline.run(file, into: account.id)
        #expect(secondRun.importedCount == 0)
        #expect(secondRun.duplicateCount == 8)

        let count = try await dependencies.transactionRepository.count()
        #expect(count == 8)

        // Analytics wirksam: Ausgaben enthalten die MetaMask-Käufe
        let all = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let calculator = AnalyticsCalculator(baseCurrency: .eur)
        let snapshot = calculator.snapshot(transactions: all, categories: [], calendar: .current)
        #expect(snapshot.totalSpending > 0)
    }
}
