import Foundation
import Testing

@testable import FinanceTracker

@Suite("GoCardlessDecoding")
struct GoCardlessDecodingTests {
    @Test("Institutions-Liste wird dekodiert")
    func institutions() throws {
        let json = """
        [{"id":"SANDBOXFINANCE_SFIN000033","name":"Sandbox Finance","bic":"SFINDE33XXX","maxAccessValidFor":"180d"}]
        """.data(using: .utf8)!

        let decoded = try JSONDecoder.goCardless.decode([GoCardlessInstitutionDTO].self, from: json)
        let summary = try #require(decoded.first?.summary)

        #expect(summary.id == "SANDBOXFINANCE_SFIN000033")
        #expect(summary.name == "Sandbox Finance")
        #expect(summary.transactionTotalDays == 180)
    }

    @Test("Requisition wird mit Status und Accounts dekodiert")
    func requisition() throws {
        let json = """
        {"id":"req-1","status":"LN","accounts":["acc-1","acc-2"],"link":"https://ob.gocardless.com/auth"}
        """.data(using: .utf8)!

        let dto = try JSONDecoder.goCardless.decode(GoCardlessRequisitionDTO.self, from: json)

        #expect(dto.id == "req-1")
        #expect(dto.status == "LN")
        #expect(dto.accounts == ["acc-1", "acc-2"])
        #expect(dto.link?.absoluteString.contains("auth") == true)
    }

    @Test("Transactions werden inkl. booked/pending und Datumsformaten gemappt")
    func transactionsMapping() throws {
        let json = """
        {"transactions":{
            "booked":[
                {"transactionId":"T1","bookingDate":"2026-08-20","valueDate":"2026-08-21",
                 "transactionAmount":{"amount":"-43.27","currency":"EUR"},
                 "creditorName":"REWE MARKT 123","remittanceInformationUnstructured":"Einkauf"},
                {"transactionId":"T2","bookingDate":"2026-08-19",
                 "transactionAmount":{"amount":"2850.00","currency":"EUR"},
                 "debtorName":"Acme GmbH"}
            ],
            "pending":[
                {"entryReference":"P9","valueDate":"2026-08-24",
                 "transactionAmount":{"amount":"-18.30","currency":"EUR"},
                 "creditorName":"MCDONALDS"}
            ]
        }}
        """.data(using: .utf8)!

        let response = try JSONDecoder.goCardless.decode(GoCardlessTransactionsResponseDTO.self, from: json)
        let booked: [RemoteBankTransaction] = (response.transactions.booked ?? []).compactMap {
            GoCardlessBankDataProvider.mapTransactionForTesting($0, state: RemoteBankTransaction.State.booked)
        }
        let pendingMapped: [RemoteBankTransaction] = (response.transactions.pending ?? []).compactMap {
            GoCardlessBankDataProvider.mapTransactionForTesting($0, state: RemoteBankTransaction.State.pending)
        }
        let mapped = booked + pendingMapped

        #expect(mapped.count == 3)

        let rewe = mapped[0]
        #expect(rewe.amount.amount == Decimal(string: "-43.27")!)
        #expect(rewe.creditorName == "REWE MARKT 123")

        let salary = mapped[1]
        #expect(salary.amount.amount == 2850)
        #expect(salary.debtorName == "Acme GmbH")

        let pending = mapped[2]
        #expect(pending.state == .pending)
        #expect(pending.externalID == "P9")
    }
}
