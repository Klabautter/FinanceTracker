import Foundation

actor GoCardlessAccessTokenStore {
    struct Token: Sendable, Equatable {
        let value: String
        let expiresAt: Date
    }

    private var cached: Token?

    func validToken(now: Date, safetyMargin: TimeInterval = 60) -> String? {
        guard let cached else { return nil }
        guard now < cached.expiresAt.addingTimeInterval(-safetyMargin) else { return nil }
        return cached.value
    }

    func store(token: Token) {
        cached = token
    }

    func invalidate() {
        cached = nil
    }
}
