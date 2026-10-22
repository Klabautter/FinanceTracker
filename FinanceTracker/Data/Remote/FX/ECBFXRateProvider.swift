import Foundation

/// P2 Live-FX (EZB) mit Datei-Cache und statischem Fallback.
///
/// - Feed: EZB Tageskurse (1 EUR → Fremdwährung), Inversion zu
///   1 Einheit → EUR per Decimal-Division (kein Double-Umweg).
/// - Cache (#33): Datei unter Application Support/FinanceTracker/FX/
///   ecb-rates.json (JSON mit ISO8601-Datum + String-Beträgen, keine Blobs,
///   kein Secret). TTL 24h.
/// - Fallback: `CurrencyConverter.referenceEURRates` (29.08.2026).
/// - Fehlende/ungültige Kurse werden verworfen (nie 0, #17); der Aufrufer
///   meldet sie über `excludedCurrencies`.
struct ECBFXRateProvider: FXRateProvider, Sendable {
    static let feedURL = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
    /// 24h TTL für den Datei-Cache.
    static let cacheTTL: TimeInterval = 24 * 60 * 60

    private let transport: any HTTPTransport
    private let cacheURL: URL?
    private let now: @Sendable () -> Date

    init(
        transport: any HTTPTransport = URLSessionTransport(),
        cacheURL: URL? = Self.defaultCacheURL(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.cacheURL = cacheURL
        self.now = now
    }

    static func defaultCacheURL() -> URL? {
        guard let root = AppDataDirectory.root() else {
            return nil
        }
        return root
            .appendingPathComponent("FX", isDirectory: true)
            .appendingPathComponent("ecb-rates.json", isDirectory: false)
    }

    func snapshot() async -> FXRateSnapshot {
        await resolve(forceRefresh: false)
    }

    func refresh() async -> FXRateSnapshot {
        await resolve(forceRefresh: true)
    }

    private func resolve(forceRefresh: Bool) async -> FXRateSnapshot {
        let currentTime = now()
        let cached = loadCache()
        // A normal read reuses a valid cache. Explicit refresh always attempts the feed.
        if !forceRefresh, let cached, isFresh(cached, at: currentTime) {
            return cached
        }
        do {
            let feed = try await fetchLiveRates()
            let snapshot = FXRateSnapshot(
                eurPerUnit: feed.eurPerUnit,
                quoteDate: feed.quoteDate,
                fetchedAt: now(),
                source: .live
            )
            saveCache(snapshot)
            return snapshot
        } catch {
            // An existing quote remains usable, but its age and failed refresh are explicit.
            if let cached {
                return FXRateSnapshot(
                    eurPerUnit: cached.eurPerUnit,
                    quoteDate: cached.quoteDate,
                    fetchedAt: cached.fetchedAt,
                    source: .cache,
                    isStale: !isFresh(cached, at: now()),
                    refreshFailed: true
                )
            }
            return FXRateSnapshot(
                eurPerUnit: CurrencyConverter.referenceEURRates,
                quoteDate: CurrencyConverter.referenceEURQuoteDate,
                source: .fallback,
                isStale: true,
                refreshFailed: true
            )
        }
    }

    private func isFresh(_ snapshot: FXRateSnapshot, at time: Date) -> Bool {
        guard let fetchedAt = snapshot.fetchedAt else { return false }
        let age = time.timeIntervalSince(fetchedAt)
        return age >= 0 && age < Self.cacheTTL
    }

    // MARK: - Live-Feed

    private func fetchLiveRates() async throws -> ParsedFeed {
        var request = URLRequest(url: Self.feedURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ECBFXError.badStatus(response.statusCode)
        }
        let feed = try Self.parseECBFeed(data)
        guard !feed.eurPerUnit.isEmpty else { throw ECBFXError.emptyFeed }
        return feed
    }

    struct ParsedFeed: Sendable, Equatable {
        let quoteDate: Date
        let eurPerUnit: [CurrencyCode: Decimal]
    }

    /// Parses both the ECB quote date and normalized rates from the daily feed.
    static func parseECBFeed(_ data: Data) throws -> ParsedFeed {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw ECBFXError.invalidPayload
        }
        // Der Feed liefert Attribute mit einfachen Anführungszeichen
        // (`time='2026-10-12'`); beide Schreibweisen sind gültiges XML.
        let pattern = #"<Cube\b[^>]*\btime=["']([^"']+)["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let dateRange = Range(match.range(at: 1), in: text) else {
            throw ECBFXError.missingQuoteDate
        }
        let dateString = String(text[dateRange])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let quoteDate = formatter.date(from: dateString), formatter.string(from: quoteDate) == dateString else {
            throw ECBFXError.invalidQuoteDate
        }
        return ParsedFeed(quoteDate: quoteDate, eurPerUnit: try parseECBXML(data))
    }

    /// Parst EZB-XML (`<Cube currency='USD' rate='1.08'/>`, 1 EUR → Fremd)
    /// zu 1 Einheit → EUR. Ungültige/nicht-positive Einträge werden
    /// verworfen (nie 0, #17) statt ersetzt.
    static func parseECBXML(_ data: Data) throws -> [CurrencyCode: Decimal] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw ECBFXError.invalidPayload
        }
        // Minimaler, deterministischer Parser (kein XMLParser-Delegate-State):
        // sucht Cube-Tags mit currency+rate Attributen.
        var result: [CurrencyCode: Decimal] = [:]
        let pattern = #"<Cube[^>]*currency=["']([A-Z]{3})["'][^>]*rate=["']([0-9.]+)["'][^>]*/?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw ECBFXError.invalidPayload
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges == 3,
                  let currencyRange = Range(match.range(at: 1), in: text),
                  let rateRange = Range(match.range(at: 2), in: text) else { continue }
            let code = CurrencyCode(String(text[currencyRange]))
            let rateString = String(text[rateRange])
            // EZB: 1 EUR = rate Fremd → 1 Fremd = 1/rate EUR.
            guard let perEUR = Decimal(string: rateString), perEUR > 0 else { continue }
            let eurPerUnit = Decimal(1) / perEUR
            guard eurPerUnit > 0 else { continue }
            result[code] = eurPerUnit
        }
        return result
    }

    // MARK: - Datei-Cache (#33)

    struct CachePayload: Codable, Sendable {
        let fetchedAt: Date
        /// Optional to keep previously written v1 cache files readable.
        let quoteDate: Date?
        /// String-Beträge (exakte Decimal-Roundtrips, keine Floats).
        let eurPerUnit: [String: String]
    }

    private func loadCache() -> FXRateSnapshot? {
        guard let cacheURL else { return nil }
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(CachePayload.self, from: data) else { return nil }
        var rates: [CurrencyCode: Decimal] = [:]
        for (code, raw) in payload.eurPerUnit {
            // Korrupte Einträge verwerfen (nie als 0 maskieren, #23).
            guard let value = Decimal(string: raw), value > 0 else { continue }
            rates[CurrencyCode(code)] = value
        }
        guard !rates.isEmpty else { return nil }
        return FXRateSnapshot(
            eurPerUnit: rates,
            quoteDate: payload.quoteDate,
            fetchedAt: payload.fetchedAt,
            source: .cache,
            isStale: !isFresh(
                FXRateSnapshot(eurPerUnit: rates, quoteDate: payload.quoteDate, fetchedAt: payload.fetchedAt, source: .cache),
                at: now()
            )
        )
    }

    private func saveCache(_ snapshot: FXRateSnapshot) {
        guard let cacheURL, snapshot.source == .live, let fetchedAt = snapshot.fetchedAt else { return }
        let payload = CachePayload(
            fetchedAt: fetchedAt,
            quoteDate: snapshot.quoteDate,
            eurPerUnit: Dictionary(
                uniqueKeysWithValues: snapshot.eurPerUnit.map {
                    ($0.key.rawValue, NSDecimalNumber(decimal: $0.value).stringValue)
                }
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}

enum ECBFXError: Error, Equatable {
    case badStatus(Int)
    case invalidPayload
    case missingQuoteDate
    case invalidQuoteDate
    case emptyFeed
}
