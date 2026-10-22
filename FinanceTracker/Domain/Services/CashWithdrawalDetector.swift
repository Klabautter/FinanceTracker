import Foundation

/// Erkennt Bargeldabhebungen (Geldautomat) an Beschreibung und Händler:
/// reine Textheuristik, deterministisch, ohne I/O.
enum CashWithdrawalDetector {
    /// Groß geschrieben verglichen; „CASHBACK" ist ausdrücklich keine Abhebung.
    static let keywords: [String] = [
        "GELDAUTOMAT", "BARGELDAUSZAHLUNG", "BARGELDAUSZ", "BARGELDABHEBUNG", "BARABHEBUNG",
        "BARGELD", "BANKOMAT", "ATM", "CASH WITHDRAWAL", "WITHDRAWAL", "AUSZAHLUNG GAA", " GAA ", "CASHPOINT"
    ]
    static let exclusions: [String] = ["CASHBACK", "CASH BACK"]

    static func isWithdrawal(_ transaction: Transaction) -> Bool {
        guard transaction.amount.isNegative else { return false }
        guard transaction.status != .reversed, transaction.status != .cancelled else { return false }
        let haystack = " " + [transaction.rawDescription, transaction.rawMerchantName, transaction.merchantDisplayName]
            .compactMap { $0 }
            .joined(separator: " ")
            .uppercased() + " "
        if exclusions.contains(where: { haystack.contains($0) }) { return false }
        return keywords.contains { keyword in
            if keyword == "ATM" {
                // „ATM" nur als eigenes Wort (sonst trifft z. B. „ATMOSPHERE").
                return haystack.range(of: #"(^|[^A-Z])ATM([^A-Z]|$)"#, options: .regularExpression) != nil
            }
            return haystack.contains(keyword)
        }
    }
}
