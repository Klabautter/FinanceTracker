import Foundation

struct Money: Hashable, Codable, Sendable {
    let amount: Decimal
    let currency: CurrencyCode

    init(amount: Decimal, currency: CurrencyCode) {
        self.amount = amount
        self.currency = currency
    }

    static func zero(in currency: CurrencyCode) -> Money {
        Money(amount: 0, currency: currency)
    }

    var isNegative: Bool { amount < 0 }
    var isPositive: Bool { amount > 0 }

    func negated() -> Money {
        Money(amount: -amount, currency: currency)
    }
}

extension Money {
    static func +(lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Cannot add \(lhs.currency) and \(rhs.currency)")
        return Money(amount: lhs.amount + rhs.amount, currency: lhs.currency)
    }

    static func -(lhs: Money, rhs: Money) -> Money {
        lhs + rhs.negated()
    }
}
