import Foundation
import Testing

@testable import FinanceTracker

@Suite("BankErrorPresentation")
struct BankErrorPresentationTests {
    @Test("Statuscodes werden in Ursache und nächsten Schritt übersetzt, ohne Rohantwort")
    func statusCodesBecomeSentences() {
        let unauthorized = BankErrorPresentation.message(
            for: BankProviderError.requestFailed(endpoint: "/accounts", status: 401, body: #"{"error":"secret"}"#)
        )
        #expect(unauthorized.contains("neu verbinden"))
        #expect(unauthorized.contains("401"))
        #expect(!unauthorized.contains("secret"))

        let rateLimited = BankErrorPresentation.message(for: BankProviderError.requestFailed(endpoint: "/x", status: 429, body: nil))
        #expect(rateLimited.contains("später"))

        let offline = BankErrorPresentation.message(for: URLError(.notConnectedToInternet))
        #expect(offline.contains("Internet"))
    }
}
