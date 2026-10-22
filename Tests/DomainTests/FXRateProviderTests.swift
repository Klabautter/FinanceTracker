import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@Suite("FXRateProvider")
struct FXRateProviderTests {
    /// EZB-Fixture (kein Netzwerk im Test, kein Secret).
    static let ecbFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
      <Cube>
        <Cube time="2026-08-28">
          <Cube currency="USD" rate="1.0862"/>
          <Cube currency="GBP" rate="0.85470"/>
          <Cube currency="CHF" rate="0.9433"/>
          <Cube currency="JPY" rate="161.32"/>
          <Cube currency="XXX" rate="0"/>
          <Cube currency="YYY" rate="nonsense"/>
        </Cube>
      </Cube>
    </gesmes:Envelope>
    """

    struct StubTransport: HTTPTransport, Sendable {
        let data: Data
        let status: Int

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }
    }

    struct FailingTransport: HTTPTransport, Sendable {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw URLError(.notConnectedToInternet)
        }
    }

    actor CountingFailingTransport: HTTPTransport {
        private(set) var requests = 0

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests += 1
            throw URLError(.notConnectedToInternet)
        }
    }

    /// Deterministischer Provider-Double für die AppDependencies-Verdrahtung.
    struct StubFXProvider: FXRateProvider, Sendable {
        let snapshotToReturn: FXRateSnapshot

        func snapshot() async -> FXRateSnapshot { snapshotToReturn }
    }

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("ecb-rates.json")
    }

    @Test("EZB-Feed mit einfachen Anführungszeichen wird gelesen (Schreibweise des Live-Feeds)")
    func parsesSingleQuotedFeed() throws {
        let liveStyle = Self.ecbFixture.replacingOccurrences(of: "\"", with: "'")
        let feed = try ECBFXRateProvider.parseECBFeed(Data(liveStyle.utf8))
        let doubleQuoted = try ECBFXRateProvider.parseECBFeed(Data(Self.ecbFixture.utf8))
        #expect(feed == doubleQuoted)
        #expect(feed.eurPerUnit[.usd] != nil)
    }

    @Test("EZB-Parser invertiert Kurse (1 EUR → Fremd wird 1 Fremd → EUR)")
    func parsesAndInverts() throws {
        let rates = try ECBFXRateProvider.parseECBXML(Data(Self.ecbFixture.utf8))
        // USD: 1/1.0862 ≈ 0.92064 EUR.
        let usd = try #require(rates[.usd])
        #expect(abs(NSDecimalNumber(decimal: usd).doubleValue - 0.92064) < 0.00001)
        // GBP: 1/0.85470 ≈ 1.17000 EUR.
        let gbp = try #require(rates[.gbp])
        #expect(abs(NSDecimalNumber(decimal: gbp).doubleValue - 1.17000) < 0.00001)
        // Ungültige/0-Kurse werden verworfen, nie 0 (#17).
        #expect(rates[CurrencyCode("XXX")] == nil)
        #expect(rates[CurrencyCode("YYY")] == nil)
        for (_, rate) in rates {
            #expect(rate > 0)
        }
    }

    @Test("Live-Snapshot wird aus Fixture gebaut und Converter rechnet damit")
    func liveSnapshotAndConverter() async throws {
        let provider = ECBFXRateProvider(
            transport: StubTransport(data: Data(Self.ecbFixture.utf8), status: 200),
            cacheURL: tempCacheURL()
        )
        let snapshot = await provider.snapshot()
        #expect(snapshot.source == .live)
        #expect(snapshot.quoteDate != nil)
        #expect(snapshot.fetchedAt != nil)
        #expect(snapshot.quoteDate != snapshot.fetchedAt)
        let converter = await provider.converter()
        // 100 USD → EUR nutzt den Live-Kurs (≈ 92.06), nicht den statischen 0.92-Fallback allein.
        let converted = try #require(converter.convert(Money(amount: 100, currency: .usd), to: .eur))
        let value = NSDecimalNumber(decimal: converted.amount).doubleValue
        #expect(abs(value - 92.064) < 0.01)
        // Fehlender Kurs = nil (kein stiller Fallback, #17).
        #expect(converter.convert(Money(amount: 10, currency: CurrencyCode("XYZ")), to: .eur) == nil)
    }

    @Test("Netzwerkfehler → statischer Fallback (Referenzkurse 29.08.2026)")
    func networkFailureFallsBack() async {
        let provider = ECBFXRateProvider(
            transport: FailingTransport(),
            cacheURL: tempCacheURL()
        )
        let snapshot = await provider.snapshot()
        #expect(snapshot.source == .fallback)
        #expect(snapshot.eurPerUnit == CurrencyConverter.referenceEURRates)
        #expect(snapshot.quoteDate == CurrencyConverter.referenceEURQuoteDate)
        #expect(snapshot.fetchedAt == nil)
        #expect(snapshot.isStale)
        #expect(snapshot.refreshFailed)
    }

    @Test("Gültiger Datei-Cache vermeidet Netzwerk (Source cache)")
    func validCacheShortCircuits() async throws {
        let cacheURL = tempCacheURL()
        // Erst Live laden → schreibt Cache-Datei.
        let live = ECBFXRateProvider(
            transport: StubTransport(data: Data(Self.ecbFixture.utf8), status: 200),
            cacheURL: cacheURL
        )
        let first = await live.snapshot()
        #expect(first.source == .live)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        // Dann mit failing Transport: gültiger Cache (TTL 24h) gewinnt.
        let cached = ECBFXRateProvider(
            transport: FailingTransport(),
            cacheURL: cacheURL
        )
        let second = await cached.snapshot()
        #expect(second.source == .cache)
        #expect(second.eurPerUnit == first.eurPerUnit)
    }

    @Test("Explizite Aktualisierung umgeht gültigen Cache und markiert den Abruffehler")
    func refreshBypassesFreshCache() async throws {
        let cacheURL = tempCacheURL()
        let currentTime = Date(timeIntervalSince1970: 1_790_000_000)
        let now: @Sendable () -> Date = { currentTime }
        let initial = ECBFXRateProvider(
            transport: StubTransport(data: Data(Self.ecbFixture.utf8), status: 200),
            cacheURL: cacheURL,
            now: now
        )
        let cachedSnapshot = await initial.snapshot()
        #expect(cachedSnapshot.source == .live)

        let transport = CountingFailingTransport()
        let provider = ECBFXRateProvider(transport: transport, cacheURL: cacheURL, now: now)
        let refreshed = await provider.refresh()

        #expect(await transport.requests == 1)
        #expect(refreshed.source == .cache)
        #expect(refreshed.eurPerUnit == cachedSnapshot.eurPerUnit)
        #expect(refreshed.quoteDate == cachedSnapshot.quoteDate)
        #expect(refreshed.fetchedAt == cachedSnapshot.fetchedAt)
        #expect(!refreshed.isStale)
        #expect(refreshed.refreshFailed)
    }

    @Test("EZB-Feed muss ein strikt gültiges Kursdatum enthalten")
    func quoteDateIsRequiredAndStrict() {
        let noDate = Self.ecbFixture.replacingOccurrences(of: " time=\"2026-08-28\"", with: "")
        #expect(throws: ECBFXError.missingQuoteDate) {
            try ECBFXRateProvider.parseECBFeed(Data(noDate.utf8))
        }

        let invalidDate = Self.ecbFixture.replacingOccurrences(of: "2026-08-28", with: "2026-02-30")
        #expect(throws: ECBFXError.invalidQuoteDate) {
            try ECBFXRateProvider.parseECBFeed(Data(invalidDate.utf8))
        }
    }

    // MARK: - Wiring: Provider → Pipeline → Analytics/Budget

    private static var wiringCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func wiringExpense(
        amount: Decimal,
        currency: CurrencyCode,
        categoryID: UUID?,
        day: Int = 4
    ) -> Transaction {
        Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .manual,
            externalID: UUID().uuidString,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: amount, currency: currency),
            bookedAt: Self.wiringCalendar.date(from: DateComponents(year: 2026, month: 3, day: day))!,
            rawDescription: "Wiring",
            rawMerchantName: "Wiring",
            merchantDisplayName: "Wiring",
            categoryID: categoryID
        )
    }

    /// Fallback bei failing Transport: Fehlender Kurs = nil (nie still 0,
    /// #17) und wird über `excludedCurrencies` gemeldet, in Analytics UND
    /// Budget-Pipeline mit demselben Provider-Converter.
    @Test("Wiring: Fallback meldet fehlenden Kurs (nil + excludedCurrencies)")
    func fallbackWiringReportsMissingRate() async {
        let provider = ECBFXRateProvider(
            transport: FailingTransport(),
            cacheURL: tempCacheURL()
        )
        let snapshot = await provider.snapshot()
        #expect(snapshot.source == .fallback)

        let converter = CurrencyConverter(eurPerUnit: snapshot.eurPerUnit)
        let exotic = CurrencyCode("XYZ")
        // Fehlender Kurs = nil, kein stiller Fallback-Wert (#17).
        #expect(converter.convert(Money(amount: -100, currency: exotic), to: .eur) == nil)

        let categoryID = UUID()
        let transactions = [wiringExpense(amount: -100, currency: exotic, categoryID: categoryID)]

        let analytics = AnalyticsCalculator(baseCurrency: .eur, converter: converter).snapshot(
            transactions: transactions,
            categories: [],
            calendar: Self.wiringCalendar
        )
        #expect(analytics.excludedForeignTransactionCount == 1)
        #expect(analytics.excludedCurrencies == [exotic])
        // Ausgeschlossen heißt: nicht in den Summen (0 aus Exklusion,
        // nicht aus 0-Kurs-Maskierung).
        #expect(analytics.totalSpending == 0)
        #expect(analytics.convertedForeignTransactionCount == 0)

        let budget = Budget(name: "Wiring", amount: 500, currency: .eur, categoryIDs: [categoryID])
        let period = DateInterval(
            start: Self.wiringCalendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!,
            end: Self.wiringCalendar.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        )
        let budgetResult = BudgetContributionCalculator(converter: converter).result(
            budget: budget,
            transactions: transactions,
            splitLines: [],
            period: period,
            calendar: Self.wiringCalendar
        )
        #expect(budgetResult.contributions.isEmpty)
        #expect(budgetResult.excludedCurrencies == [exotic])
    }

    /// Cache-Hit: Die Pipeline rechnet mit den gecachten (Fixture-)Kursen,
    /// nicht mit den statischen Referenzkursen.
    @Test("Wiring: Cache-Hit speist die Pipeline mit gecachten Kursen")
    func cacheHitWiringUsesCachedRates() async throws {
        let cacheURL = tempCacheURL()
        let live = ECBFXRateProvider(
            transport: StubTransport(data: Data(Self.ecbFixture.utf8), status: 200),
            cacheURL: cacheURL
        )
        let first = await live.snapshot()
        #expect(first.source == .live)

        let cachedProvider = ECBFXRateProvider(
            transport: FailingTransport(),
            cacheURL: cacheURL
        )
        let second = await cachedProvider.snapshot()
        #expect(second.source == .cache)

        let converter = CurrencyConverter(eurPerUnit: second.eurPerUnit)
        let converted = try #require(converter.convert(Money(amount: 100, currency: .usd), to: .eur))
        let value = NSDecimalNumber(decimal: converted.amount).doubleValue
        // Fixture-Kurs (≈ 92.06), nicht der statische 0.92-Fallback (92.00).
        #expect(abs(value - 92.064) < 0.01)
        #expect(converted.amount != Decimal(string: "92")!)
    }

    /// Provider → Pipeline → Analytics E2E (#25, #28): Live-Fixture-Kurse
    /// fließen identisch in Analytics- und Budget-Summen ein.
    @Test("Wiring: Provider-Kurse gelten gleich in Analytics und Budget")
    func providerPipelineAnalyticsE2E() async throws {
        let provider = ECBFXRateProvider(
            transport: StubTransport(data: Data(Self.ecbFixture.utf8), status: 200),
            cacheURL: tempCacheURL()
        )
        let snapshot = await provider.snapshot()
        #expect(snapshot.source == .live)
        let converter = CurrencyConverter(eurPerUnit: snapshot.eurPerUnit)

        let categoryID = UUID()
        let transactions = [wiringExpense(amount: -300, currency: .usd, categoryID: categoryID)]

        let analytics = AnalyticsCalculator(baseCurrency: .eur, converter: converter).snapshot(
            transactions: transactions,
            categories: [],
            calendar: Self.wiringCalendar
        )
        #expect(analytics.convertedForeignTransactionCount == 1)
        #expect(analytics.convertedCurrencies == [.usd])
        #expect(analytics.excludedForeignTransactionCount == 0)
        // Live-Kurs (≈ 276.19), nicht statisch 276.00.
        #expect(analytics.totalSpending != Decimal(string: "276")!)

        let budget = Budget(name: "Reisen", amount: 500, currency: .eur, categoryIDs: [categoryID])
        let period = DateInterval(
            start: Self.wiringCalendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!,
            end: Self.wiringCalendar.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        )
        let contributionCalculator = BudgetContributionCalculator(converter: converter)
        let budgetTotal = contributionCalculator.total(contributionCalculator.contributions(
            budget: budget,
            transactions: transactions,
            splitLines: [],
            period: period,
            calendar: Self.wiringCalendar
        ))
        // Gleiche effektive Semantik (#28): Budget == Analytics.
        #expect(budgetTotal == analytics.totalSpending)
    }

    /// Verdrahtung in AppDependencies: injizierter Provider wird verwendet
    /// (kein Singleton, kein globaler Zugriff).
    @Test("AppDependencies verdrahtet den injizierten FX-Provider")
    func appDependenciesWiresFXProvider() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let stubSnapshot = FXRateSnapshot(
            eurPerUnit: CurrencyConverter.referenceEURRates,
            fetchedAt: Date(timeIntervalSince1970: 1_786_000_000),
            source: .fallback
        )
        let dependencies = AppDependencies.make(
            container: store.container,
            baseCurrency: .eur,
            fxRateProvider: StubFXProvider(snapshotToReturn: stubSnapshot)
        )
        #expect(await dependencies.fxRateProvider.snapshot() == stubSnapshot)
    }

    /// Default-Verdrahtung: Ohne Override liefert AppDependencies den
    /// EZB-Provider (lazy, hier ohne Snapshot, also ohne Netzwerk).
    @Test("AppDependencies-Default ist der EZB-Provider")
    func appDependenciesDefaultsToECB() throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        #expect(dependencies.fxRateProvider is ECBFXRateProvider)
    }
}
