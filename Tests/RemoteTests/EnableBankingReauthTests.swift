import Foundation
import Testing

@testable import FinanceTracker

/// Neuanmeldung einer bestehenden Verbindung: dasselbe Konto wiedererkennen,
/// volle Freigabedauer anfragen.
@Suite("EnableBankingReauth")
struct EnableBankingReauthTests {
    private actor RoutingTransport: HTTPTransport {
        private(set) var paths: [String] = []
        private(set) var authBody: Data?
        let details: String

        init(details: String = #"{"uid":"session-uid","currency":"EUR","identification_hash":"stable-hash"}"#) {
            self.details = details
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try #require(request.url)
            paths.append(url.path)
            let json: String
            switch true {
            case url.path.hasSuffix("/aspsps"):
                json = #"{"aspsps":[{"name":"VR Bank Beispiel","country":"DE","maximum_consent_validity":15552000}]}"#
            case url.path.hasSuffix("/auth"):
                authBody = request.httpBody
                json = #"{"url":"https://bank.example/auth","authorization_id":"auth-1"}"#
            case url.path.hasSuffix("/details"):
                json = details
            default:
                json = #"{"transactions":[],"continuation_key":null}"#
            }
            return (Data(json.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    private func provider(_ transport: RoutingTransport) -> EnableBankingBankDataProvider {
        EnableBankingBankDataProvider(redirectURL: "https://enablebanking.com/redirect", transport: transport) {
            EnableBankingCredentials(applicationID: "test-application", privateKeyPEM: EnableBankingTestKeys.privatePEM)
        }
    }

    @Test("Ohne geladene Bankliste wird die maximale Freigabedauer vorher nachgeladen")
    func consentMaximumIsLoadedBeforeAuth() async throws {
        let transport = RoutingTransport()
        _ = try await provider(transport).createConnection(institutionID: "DE|VR Bank Beispiel", redirectURL: nil)

        let paths = await transport.paths
        #expect(paths.first?.hasSuffix("/aspsps") == true)
        let body = try #require(await transport.authBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let access = try #require(json["access"] as? [String: Any])
        let validUntil = try #require((access["valid_until"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
        let days = validUntil.timeIntervalSinceNow / 86_400
        // 90 Tage angestrebt (Bank erlaubt 180) statt 10 Tage Rückfall.
        #expect(days > 89 && days < 91)
    }

    @Test("Das Konto trägt die über Sitzungen stabile Kennung, nicht die Sitzungs-ID")
    func stableAccountIdentifier() async throws {
        let transport = RoutingTransport()
        let data = try await provider(transport).fetchAccountData(accountID: "session-uid", dateFrom: nil)
        #expect(data.account.id == "session-uid")
        #expect(data.account.providerAccountID == "stable-hash")
    }
}
