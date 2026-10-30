import Foundation
import Testing

@testable import FinanceTracker

@Suite("TransactionFingerprinter")
struct TransactionFingerprinterTests {
    private let accountID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let bookingDate = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("Gleiche Eingaben erzeugen gleichen Fingerprint")
    func determinism() {
        let a = TransactionFingerprinter.fingerprint(
            source: .demo,
            accountID: accountID,
            bookingDate: bookingDate,
            amount: Money(amount: Decimal(string: "-43.27")!, currency: .eur),
            merchantOrDescription: "REWE SAGT DANKE"
        )
        let b = TransactionFingerprinter.fingerprint(
            source: .demo,
            accountID: accountID,
            bookingDate: bookingDate,
            amount: Money(amount: Decimal(string: "-43.27")!, currency: .eur),
            merchantOrDescription: "REWE SAGT DANKE"
        )

        #expect(a == b)
        #expect(a.count == 64)
    }

    @Test("Text ist case- und whitespace-insensitiv")
    func textNormalization() {
        let a = TransactionFingerprinter.fingerprint(
            source: .demo,
            accountID: accountID,
            bookingDate: bookingDate,
            amount: Money(amount: -10, currency: .eur),
            merchantOrDescription: "rewe  sagt   danke!!!"
        )
        let b = TransactionFingerprinter.fingerprint(
            source: .demo,
            accountID: accountID,
            bookingDate: bookingDate,
            amount: Money(amount: -10, currency: .eur),
            merchantOrDescription: "REWE SAGT DANKE"
        )

        #expect(a == b)
    }

    @Test("Beträge werden kanonisch serialisiert ohne Identitätsrundung")
    func amountNormalization() {
        func fp(_ amount: Decimal) -> String {
            TransactionFingerprinter.fingerprint(
                source: .genericCSV,
                accountID: accountID,
                bookingDate: bookingDate,
                amount: Money(amount: amount, currency: .eur),
                merchantOrDescription: "X"
            )
        }

        #expect(fp(Decimal(string: "-10.00")!) == fp(-10))
        #expect(fp(Decimal(string: "-10.004")!) != fp(-10))
    }

    @Test("Unterschiedliche Quelle erzeugt anderen Fingerprint")
    func differentSource() {
        let a = TransactionFingerprinter.fingerprint(
            source: .legacyCardExportCSV,
            accountID: accountID,
            bookingDate: bookingDate,
            amount: Money(amount: -10, currency: .eur),
            merchantOrDescription: "X"
        )
        let b = TransactionFingerprinter.fingerprint(
            source: .legacyCardStatementCSV,
            accountID: accountID,
            bookingDate: bookingDate,
            amount: Money(amount: -10, currency: .eur),
            merchantOrDescription: "X"
        )

        #expect(a != b)
    }

    @Test("Gleicher Betrag in unterschiedlicher Währung erzeugt anderen Fingerprint")
    func differentCurrency() {
        let a = TransactionFingerprinter.fingerprint(
            source: .demo,
            accountID: accountID,
            bookingDate: bookingDate,
            amount: Money(amount: -10, currency: .eur),
            merchantOrDescription: "X"
        )
        let b = TransactionFingerprinter.fingerprint(
            source: .demo,
            accountID: accountID,
            bookingDate: bookingDate,
            amount: Money(amount: -10, currency: .usd),
            merchantOrDescription: "X"
        )

        #expect(a != b)
    }

    @Test("Beträge werden kanonisch serialisiert ohne Identitätsrundung")
    func canonicalAmounts() {
        func fp(_ amount: Decimal) -> String {
            TransactionFingerprinter.fingerprint(
                source: .genericCSV,
                accountID: accountID,
                bookingDate: bookingDate,
                amount: Money(amount: amount, currency: .eur),
                merchantOrDescription: "X"
            )
        }

        #expect(fp(10) == fp(Decimal(string: "10.00")!))
        #expect(fp(10) != fp(Decimal(string: "10.004")!))
        #expect(fp(-43.270) == fp(Decimal(string: "-43.27")!))
    }
}
