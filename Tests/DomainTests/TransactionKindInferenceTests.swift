import Foundation
import Testing

@testable import FinanceTracker

@Suite("TransactionKindInference")
struct TransactionKindInferenceTests {
    @Test("Unbekannter Typ wird aus dem Betragssignal abgeleitet")
    func infersFromAmountSign() {
        #expect(
            TransactionKindInference.inferredKind(
                for: Money(amount: -42.50, currency: .eur),
                current: .unknown
            ) == .purchase
        )
        #expect(
            TransactionKindInference.inferredKind(
                for: Money(amount: 2850, currency: .eur),
                current: .unknown
            ) == .income
        )
        #expect(
            TransactionKindInference.inferredKind(
                for: Money(amount: 0, currency: .eur),
                current: .unknown
            ) == .income
        )
    }

    @Test("Explizite Typen bleiben unverändert")
    func keepsExplicitKinds() {
        #expect(
            TransactionKindInference.inferredKind(
                for: Money(amount: -42.50, currency: .eur),
                current: .income
            ) == .income
        )
        #expect(
            TransactionKindInference.inferredKind(
                for: Money(amount: 100, currency: .eur),
                current: .transfer
            ) == .transfer
        )
        #expect(
            TransactionKindInference.inferredKind(
                for: Money(amount: 100, currency: .eur),
                current: .refund
            ) == .refund
        )
        #expect(
            TransactionKindInference.inferredKind(
                for: Money(amount: -5, currency: .eur),
                current: .purchase
            ) == .purchase
        )
    }

    @Test("Starke Eigenübertrags-Signale werden als Transfer erkannt")
    func infersStrongTransferSignals() {
        for description in ["Sparrate 08/2026", "Umbuchung Urlaub", "Eigenübertrag Tagesgeld"] {
            #expect(
                TransactionKindInference.inferredKind(
                    for: Money(amount: -400, currency: .eur),
                    current: .unknown,
                    rawDescription: description,
                    merchantName: "Eigenes Konto"
                ) == .transfer
            )
        }

        #expect(
            TransactionKindInference.inferredKind(
                for: Money(amount: -400, currency: .eur),
                current: .unknown,
                rawDescription: "Sparrate 08/2026",
                merchantName: "ETF Depot GmbH"
            ) == .purchase
        )

        #expect(
            TransactionKindInference.inferredKind(
                for: Money(amount: -400, currency: .eur),
                current: .unknown,
                rawDescription: "Überweisung Rechnung",
                merchantName: "Empfänger"
            ) == .purchase
        )
    }

    @Test("Ausdrücklich als Erstattung bezeichneter Zahlungseingang ist eine Erstattung, keine Einnahme")
    func infersStrongRefundSignals() {
        for description in ["Refund", "Rückerstattung Bestellung 123", "ERSTATTUNG", "Retoure 4711"] {
            #expect(
                TransactionKindInference.inferredKind(
                    for: Money(amount: Decimal(string: "39.99")!, currency: .eur),
                    current: .unknown,
                    rawDescription: description,
                    merchantName: "Amazon EU"
                ) == .refund
            )
        }
        // Nur ganze Wörter und nur Zahlungseingänge.
        #expect(
            TransactionKindInference.inferredKind(
                for: Money(amount: 812, currency: .eur),
                current: .unknown,
                rawDescription: "Steuererstattung 2025",
                merchantName: "Finanzamt"
            ) == .income
        )
        #expect(
            TransactionKindInference.inferredKind(
                for: Money(amount: -20, currency: .eur),
                current: .unknown,
                rawDescription: "Refund",
                merchantName: "Amazon EU"
            ) == .purchase
        )
    }
}
