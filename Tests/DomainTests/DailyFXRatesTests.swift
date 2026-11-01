import Foundation
import Testing

@testable import FinanceTracker

@Suite("Tageskurse für Buchungen")
struct DailyFXRatesTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func usdPurchase(_ amount: Decimal, on day: Date, original: (Decimal, CurrencyCode)? = nil) -> Transaction {
        Transaction(
            accountID: UUID(),
            source: .genericCSV,
            amount: Money(amount: -amount, currency: .usd),
            bookedAt: day,
            originalCurrency: original?.1,
            originalAmount: original?.0
        )
    }

    /// 1 USD in EUR: Freitag 0,90, Montag 0,80.
    private var daily: DailyFXRates {
        DailyFXRates([
            2026_10_02: [.usd: Decimal(string: "0.9")!],
            2026_10_05: [.usd: Decimal(string: "0.8")!]
        ])
    }

    @Test("Kurs vom Tag der Buchung, am Wochenende der letzte Werktag davor")
    func rateOfTheDay() {
        let converter = CurrencyConverter(eurPerUnit: [.usd: Decimal(string: "0.5")!], daily: daily)
        #expect(converter.rate(from: .usd, to: .eur, on: date(2026, 10, 2)) == Decimal(string: "0.9")!)
        #expect(converter.rate(from: .usd, to: .eur, on: date(2026, 10, 4)) == Decimal(string: "0.9")!)
        #expect(converter.rate(from: .usd, to: .eur, on: date(2026, 10, 5)) == Decimal(string: "0.8")!)
        // Ohne Tageskurs in Reichweite gilt der aktuelle Kurs.
        #expect(converter.rate(from: .usd, to: .eur, on: date(2026, 9, 1)) == Decimal(string: "0.5")!)
        #expect(converter.rate(from: .usd, to: .eur, on: date(2026, 10, 20)) == Decimal(string: "0.5")!)
    }

    @Test("Exakter Gegenwert der Buchung schlägt jeden Kurs")
    func exactOriginalAmount() {
        let converter = CurrencyConverter(eurPerUnit: [.usd: Decimal(string: "0.5")!], daily: daily)
        let exact = usdPurchase(Decimal(string: "4.77")!, on: date(2026, 10, 2), original: (4, .eur))
        #expect(converter.convert(exact, to: .eur) == Money(amount: -4, currency: .eur))
        let byDay = usdPurchase(10, on: date(2026, 10, 5))
        #expect(converter.convert(byDay, to: .eur) == Money(amount: -8, currency: .eur))
    }

    @Test("Ausgaben in der Auswertung zum Tageskurs, Stände zum aktuellen Kurs")
    func analyticsUseDailyRates() {
        let converter = CurrencyConverter(eurPerUnit: [.usd: Decimal(string: "0.5")!], daily: daily)
        let snapshot = AnalyticsCalculator(baseCurrency: .eur, converter: converter)
            .snapshot(transactions: [usdPurchase(10, on: date(2026, 10, 2)), usdPurchase(10, on: date(2026, 10, 5))], categories: [], calendar: calendar)
        #expect(snapshot.totalSpending == 17)
        #expect(converter.convert(Money(amount: 100, currency: .usd), to: .eur) == Money(amount: 50, currency: .eur))
    }

    @Test("EZB-Historie wird je Tag gelesen, ungültige Kurse verworfen")
    func parsesECBHistory() throws {
        let xml = """
        <gesmes:Envelope><Cube>
        <Cube time="2026-10-05"><Cube currency="USD" rate="1.25"/><Cube currency="SEK" rate="11.0"/></Cube>
        <Cube time='2026-10-02'><Cube currency='USD' rate='1.1111'/><Cube currency='DKK' rate='0'/></Cube>
        </Cube></gesmes:Envelope>
        """
        let days = try ECBFXHistory.parseHistory(Data(xml.utf8))
        #expect(days[2026_10_05]?[.usd] == Decimal(1) / Decimal(string: "1.25")!)
        #expect(days[2026_10_05]?[CurrencyCode("SEK")] != nil)
        #expect(days[2026_10_02]?[.usd] != nil)
        #expect(days[2026_10_02]?[CurrencyCode("DKK")] == nil)
    }

    @Test("Anbieter hängt die Historie an den Snapshot und speichert sie")
    func providerAttachesHistory() async throws {
        let xml = """
        <gesmes:Envelope><Cube>
        <Cube time='2026-10-30'><Cube currency='USD' rate='1.0821'/></Cube>
        <Cube time='2026-10-29'><Cube currency='USD' rate='1.0790'/></Cube>
        </Cube></gesmes:Envelope>
        """
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fx-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let historyURL = folder.appendingPathComponent("ecb-history.json")
        let provider = ECBFXRateProvider(
            transport: FXRateProviderTests.StubTransport(data: Data(xml.utf8), status: 200),
            cacheURL: folder.appendingPathComponent("ecb-rates.json"),
            historyCacheURL: historyURL,
            loadsHistory: true
        )
        let snapshot = await provider.snapshot()
        #expect(snapshot.daily?.dayKeys == [2026_10_29, 2026_10_30])
        #expect(FileManager.default.fileExists(atPath: historyURL.path))

        // Ohne Historie (Voreinstellung) bleibt es beim aktuellen Kurs.
        let plain = await ECBFXRateProvider(
            transport: FXRateProviderTests.StubTransport(data: Data(xml.utf8), status: 200),
            cacheURL: folder.appendingPathComponent("plain.json")
        ).snapshot()
        #expect(plain.daily == nil)
    }
}
