import Foundation
import Testing

@testable import FinanceTracker

actor CountingMockTransport: HTTPTransport {
    private(set) var tokenCalls = 0
    private(set) var institutionAttempts = 0
    private(set) var lastAuthorizationHeader: String?

    var tokenExpiresAt = Date.distantFuture.addingTimeInterval(365 * 24 * 3600)
    var failNextInstitutionWith401 = false

    func setExpiry(_ date: Date) { tokenExpiresAt = date }
    func arm401() { failNextInstitutionWith401 = true }
    func counts() -> (token: Int, institutions: Int) { (tokenCalls, institutionAttempts) }
    func lastAuthHeader() -> String? { lastAuthorizationHeader }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var path = request.url?.path ?? ""
        if path.hasSuffix("/") { path.removeLast() }

        if path.hasSuffix("/token/new") {
            tokenCalls += 1
            let tokenValue = "tok-\(tokenCalls)"
            let body = "{\"access\":\"\(tokenValue)\",\"access_expires\":\"\(iso(tokenExpiresAt))\"}"
            return (Data(body.utf8), response(url: request.url!, status: 200))
        }

        if path.contains("/institutions") {
            lastAuthorizationHeader = request.value(forHTTPHeaderField: "Authorization")
            institutionAttempts += 1

            if failNextInstitutionWith401 {
                failNextInstitutionWith401 = false
                return (Data("{}".utf8), response(url: request.url!, status: 401))
            }
            return (Data("[]".utf8), response(url: request.url!, status: 200))
        }

        return (Data("[]".utf8), response(url: request.url!, status: 200))
    }

    private func iso(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func response(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

@Suite("GoCardlessTokenLifecycle")
struct GoCardlessTokenLifecycleTests {
    private func makeProvider(
        transport: CountingMockTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> GoCardlessBankDataProvider {
        GoCardlessBankDataProvider(
            transport: transport,
            credentialsProvider: { GoCardlessCredentials(secretID: "id", secretKey: "key") },
            now: now
        )
    }

    @Test("Drei authentifizierte Calls fordern den Token nur einmal an")
    func tokenCachedAcrossCalls() async throws {
        let transport = CountingMockTransport()
        let provider = makeProvider(transport: transport)

        _ = try await provider.institutions(country: "DE")
        _ = try await provider.institutions(country: "DE")
        _ = try await provider.institutions(country: "DE")

        let counts = await transport.counts()
        #expect(counts.token == 1)
        #expect(counts.institutions == 3)
    }

    @Test("Abgelaufener Token wird erneuert")
    func expiredTokenRefreshes() async throws {
        let transport = CountingMockTransport()
        await transport.setExpiry(Date(timeIntervalSinceNow: -100))

        let provider = makeProvider(transport: transport)

        _ = try await provider.institutions(country: "DE")
        let firstRound = await transport.counts().token
        #expect(firstRound >= 1)

        _ = try await provider.institutions(country: "DE")
        let secondRound = await transport.counts().token
        #expect(secondRound > firstRound)
    }

    @Test("Token innerhalb der Sicherheitsmarge wird nicht wiederverwendet")
    func safetyMarginForcesRefresh() async throws {
        let transport = CountingMockTransport()
        await transport.setExpiry(Date(timeIntervalSinceNow: 30))

        let provider = makeProvider(transport: transport)

        _ = try await provider.institutions(country: "DE")
        _ = try await provider.institutions(country: "DE")

        let counts = await transport.counts()
        #expect(counts.token == 2)
    }

    @Test("Cachierter Bearer-Token wird für andere Endpoints verwendet")
    func cachedBearerUsed() async throws {
        let transport = CountingMockTransport()
        let provider = makeProvider(transport: transport)

        _ = try await provider.institutions(country: "AT")
        _ = try await provider.institutions(country: "DE")

        let header = await transport.lastAuthHeader()
        #expect(header == "Bearer tok-1")
        let counts = await transport.counts()
        #expect(counts.token == 1)
    }

    @Test("401 führt zu genau einem Token-Retry und erfolgreichem Wiederholungslauf")
    func singleRetryOn401() async throws {
        let transport = CountingMockTransport()
        await transport.arm401()

        let provider = makeProvider(transport: transport)

        let result = try await provider.institutions(country: "DE")

        #expect(result.isEmpty)
        let counts = await transport.counts()
        #expect(counts.institutions == 2)
        #expect(counts.token == 2)
    }
}
