import Foundation

/// Historische EZB-Referenzkurse für Buchungen in Fremdwährung.
///
/// - Erstabruf: komplette Historie (`eurofxref-hist.xml`), gespeichert ab
///   `earliestKeptDay`; danach höchstens einmal täglich die letzten 90 Tage
///   (`eurofxref-hist-90d.xml`) nachladen und zusammenführen.
/// - Cache (#33): `FX/ecb-history.json` neben dem Tageskurs-Cache, Beträge
///   als Strings. Im Speicher gehalten, damit nicht jede Ansicht die Datei
///   liest.
/// - Abgerufen werden nur die öffentlichen Kurstabellen; keine Nutzerdaten
///   verlassen das Gerät. Fehler sind nicht fatal: Ohne Historie rechnet die
///   App mit dem aktuellen Kurs wie bisher.
actor ECBFXHistory {
    static let fullHistoryURL = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.xml")!
    static let recentHistoryURL = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist-90d.xml")!
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    static let earliestKeptDay = 2018_01_01

    private let transport: any HTTPTransport
    private let cacheURL: URL?
    private let now: @Sendable () -> Date
    private var loaded: (fetchedAt: Date, rates: DailyFXRates)?
    private var didLoadCache = false

    init(transport: any HTTPTransport, cacheURL: URL?, now: @escaping @Sendable () -> Date) {
        self.transport = transport
        self.cacheURL = cacheURL
        self.now = now
    }

    static func defaultCacheURL() -> URL? {
        ECBFXRateProvider.defaultCacheURL()?
            .deletingLastPathComponent()
            .appendingPathComponent("ecb-history.json", isDirectory: false)
    }

    func rates(forceRefresh: Bool = false) async -> DailyFXRates? {
        if !didLoadCache {
            didLoadCache = true
            loaded = loadCache()
        }
        if let loaded, !forceRefresh, now().timeIntervalSince(loaded.fetchedAt) < Self.refreshInterval {
            return loaded.rates
        }
        // Ohne Bestand die ganze Historie, sonst nur die letzten 90 Tage.
        let url = loaded == nil ? Self.fullHistoryURL : Self.recentHistoryURL
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            let (data, response) = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else { throw ECBFXError.badStatus(response.statusCode) }
            var days = try Self.parseHistory(data).filter { $0.key >= Self.earliestKeptDay }
            if let existing = loaded?.rates {
                for key in existing.dayKeys where days[key] == nil {
                    days[key] = existing.rates(forDayKey: key)
                }
            }
            guard !days.isEmpty else { throw ECBFXError.emptyFeed }
            let merged = (fetchedAt: now(), rates: DailyFXRates(days))
            loaded = merged
            saveCache(merged)
            return merged.rates
        } catch {
            return loaded?.rates
        }
    }

    /// `<Cube time='2026-10-30'><Cube currency='USD' rate='1.0821'/>…</Cube>`
    /// zu yyyymmdd → 1 Einheit in EUR. Ungültige Kurse werden verworfen.
    static func parseHistory(_ data: Data) throws -> [Int: [CurrencyCode: Decimal]] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw ECBFXError.invalidPayload
        }
        let ns = text as NSString
        let dayRegex = try NSRegularExpression(pattern: #"<Cube\s+time=["'](\d{4})-(\d{2})-(\d{2})["']\s*>"#)
        let rateRegex = try NSRegularExpression(pattern: #"currency=["']([A-Z]{3})["']\s+rate=["']([0-9.]+)["']"#)
        let dayMatches = dayRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result: [Int: [CurrencyCode: Decimal]] = [:]
        for (index, match) in dayMatches.enumerated() {
            guard let year = Int(ns.substring(with: match.range(at: 1))),
                  let month = Int(ns.substring(with: match.range(at: 2))),
                  let day = Int(ns.substring(with: match.range(at: 3))) else { continue }
            let start = match.range.location + match.range.length
            let end = index + 1 < dayMatches.count ? dayMatches[index + 1].range.location : ns.length
            var rates: [CurrencyCode: Decimal] = [:]
            for rate in rateRegex.matches(in: text, range: NSRange(location: start, length: end - start)) {
                guard let perEUR = Decimal(string: ns.substring(with: rate.range(at: 2))), perEUR > 0 else { continue }
                rates[CurrencyCode(ns.substring(with: rate.range(at: 1)))] = Decimal(1) / perEUR
            }
            if !rates.isEmpty { result[year * 10_000 + month * 100 + day] = rates }
        }
        return result
    }

    // MARK: - Datei-Cache

    private struct CachePayload: Codable {
        let fetchedAt: Date
        let days: [String: [String: String]]
    }

    private func loadCache() -> (fetchedAt: Date, rates: DailyFXRates)? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(CachePayload.self, from: data) else { return nil }
        var days: [Int: [CurrencyCode: Decimal]] = [:]
        for (key, rates) in payload.days {
            guard let day = Int(key) else { continue }
            var parsed: [CurrencyCode: Decimal] = [:]
            for (code, raw) in rates {
                // Korrupte Einträge verwerfen, nie als 0 maskieren (#23).
                guard let value = Decimal(string: raw), value > 0 else { continue }
                parsed[CurrencyCode(code)] = value
            }
            days[day] = parsed
        }
        let rates = DailyFXRates(days)
        return rates.isEmpty ? nil : (payload.fetchedAt, rates)
    }

    private func saveCache(_ value: (fetchedAt: Date, rates: DailyFXRates)) {
        guard let cacheURL else { return }
        var days: [String: [String: String]] = [:]
        for key in value.rates.dayKeys {
            guard let rates = value.rates.rates(forDayKey: key) else { continue }
            days[String(key)] = Dictionary(uniqueKeysWithValues: rates.map {
                ($0.key.rawValue, NSDecimalNumber(decimal: $0.value).stringValue)
            })
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(CachePayload(fetchedAt: value.fetchedAt, days: days)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
