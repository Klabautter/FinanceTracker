import Foundation
import Testing

@testable import FinanceTracker

/// Währungen in Dateien: Ein Dollar-Betrag wird nie still als Euro des
/// Kontos gespeichert, und eine Datei in fremder Währung fällt auf.
@Suite("Import: Währung erkennen")
struct ImportCurrencyDetectionTests {
    @Test("Währung aus Zeichen oder Code im Betrag und aus der Spaltenüberschrift")
    func statedCurrency() {
        #expect(CSVMoneyParser.statedCurrency(in: "-$30.61") == .usd)
        #expect(CSVMoneyParser.statedCurrency(in: "30,61 USD") == .usd)
        #expect(CSVMoneyParser.statedCurrency(in: "12,30 €") == .eur)
        #expect(CSVMoneyParser.statedCurrency(in: "CA$12.00") == CurrencyCode("CAD"))
        #expect(CSVMoneyParser.statedCurrency(in: "Amount (USD)") == .usd)
        #expect(CSVMoneyParser.statedCurrency(in: "Betrag") == nil)
        #expect(CSVMoneyParser.statedCurrency(in: "12 € / 13 $") == nil)
        #expect(CSVMoneyParser.parseMoney("-$30.61", currencyRaw: nil, fallback: .eur) == Money(amount: Decimal(string: "-30.61")!, currency: .usd))
        #expect(CSVMoneyParser.parseMoney("-30.61", currencyRaw: nil, fallback: .eur, headerCurrency: .usd)?.currency == .usd)
        // Eine eigene Währungsspalte hat Vorrang.
        #expect(CSVMoneyParser.parseMoney("-$30.61", currencyRaw: "EUR", fallback: .eur)?.currency == .eur)
    }

    @Test("Datei ohne Spalte für die Art: Beschreibung Swap und Top-up sind Umbuchungen")
    func descriptionAsType() async throws {
        let csv = """
        Date;Description;Amount (USD)
        12.05.2026;Top-up;+50.00
        12.05.2026;Swap;-49.98
        13.05.2026;Swap Shop Berlin;-12.00
        """
        let result = try await GenericCSVProvider(fallbackCurrency: .eur).parse(ImportFile(fileName: "a.csv", data: Data(csv.utf8)))
        #expect(result.transactions.map(\.kind) == [.transfer, .transfer, .unknown])
        #expect(result.transactions.allSatisfy { $0.amount.currency == .usd })
    }

    @Test("Datei in fremder Währung: Vorschau warnt; leeres Konto lässt sich umstellen")
    @MainActor
    func foreignFileCurrency() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Karte", type: .prepaidCard, currency: .eur, source: .csvImport)
        try await dependencies.accountRepository.upsert([account])
        let csv = """
        date,description,amount,currency
        2026-05-27,Coffee,-4.50,USD
        2026-05-28,Groceries,-30.00,USD
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usd-\(UUID().uuidString).csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = ImportModel(dependencies: dependencies)
        await model.loadAccounts()
        await model.prepareFile(at: url)
        #expect(model.preparedImport?.foreignFileCurrency == .usd)
        #expect(model.preparedImport?.targetAccountIsEmpty == true)

        await model.switchTargetAccountCurrency(to: .usd)
        #expect(try await dependencies.accountRepository.account(id: account.id)?.currency == .usd)
        #expect(model.preparedImport?.foreignFileCurrency == nil)
        guard case .reviewing = model.phase else {
            Issue.record("Expected reviewing, got \(model.phase)")
            return
        }
    }
}
