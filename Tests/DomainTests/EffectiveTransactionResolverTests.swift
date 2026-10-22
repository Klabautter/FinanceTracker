import Foundation
import Testing

@testable import FinanceTracker

struct EffectiveTransactionResolverTests {
    @Test("Annotation überlagert User-Metadaten und Manual-Kind")
    func appliesAnnotation() {
        let transaction = Transaction(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            accountID: UUID(),
            source: .openBanking,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -42, currency: .eur),
            bookedAt: Date(),
            note: "alt",
            reviewed: false,
            excludedFromAnalytics: false
        )
        let annotation = TransactionAnnotation(
            transactionID: transaction.id,
            note: "neu",
            reviewed: true,
            excludedFromAnalytics: true,
            manualKindOverride: .transfer,
            tagIDs: [UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!]
        )

        let resolved = EffectiveTransactionResolver().applying(
            annotations: [annotation],
            to: [transaction]
        )

        #expect(resolved.first?.note == "neu")
        #expect(resolved.first?.reviewed == true)
        #expect(resolved.first?.excludedFromAnalytics == true)
        #expect(resolved.first?.kind == .transfer)
        #expect(resolved.first?.tagIDs == annotation.tagIDs)
    }

    @Test("Ohne Annotation bleibt Transaktion unverändert")
    func leavesTransactionUnchangedWithoutAnnotation() {
        let transaction = Transaction(
            accountID: UUID(),
            source: .genericCSV,
            amount: Money(amount: -12, currency: .eur),
            bookedAt: Date(),
            rawMerchantName: "REWE"
        )

        let resolved = EffectiveTransactionResolver().applying(annotations: [], to: [transaction])

        #expect(resolved == [transaction])
    }
}
