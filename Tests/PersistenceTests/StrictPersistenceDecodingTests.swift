import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@Suite("StrictPersistenceDecoding")
struct StrictPersistenceDecodingTests {
    @Test("Korrupter Betrag wirft Fehler statt Money(0)")
    func corruptAmountThrows() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        let txn = Transaction(
            accountID: UUID(),
            source: .genericCSV,
            amount: Money(amount: -10, currency: .eur),
            bookedAt: Date()
        )
        try await dependencies.transactionRepository.upsert([txn])

        let context = ModelContext(store.container)
        let rows = try context.fetch(FetchDescriptor<SDTransactionEntity>())
        #expect(rows.count == 1)
        rows[0].amountValue = "not-a-number"
        try context.save()

        await #expect(throws: PersistenceDecodingError.self) {
            _ = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        }
    }

    @Test("Unbekannter Status wird nicht still zu booked")
    func unknownStatusThrows() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        let txn = Transaction(
            accountID: UUID(),
            source: .demo,
            amount: Money(amount: -5, currency: .eur)
        )
        try await dependencies.transactionRepository.upsert([txn])

        let context = ModelContext(store.container)
        let rows = try context.fetch(FetchDescriptor<SDTransactionEntity>())
        rows[0].statusRaw = "mystery_status"
        try context.save()

        do {
            _ = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
            Issue.record("Expected PersistenceDecodingError.unknownStatus")
        } catch let error as PersistenceDecodingError {
            #expect(error == .unknownStatus(raw: "mystery_status"))
        }
    }

    @Test("Unbekannter Regel-Typ wirft statt merchantContains-Fallback")
    func unknownRuleConditionThrows() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        try await dependencies.ruleRepository.upsert([
            CategoryRule(priority: 1, condition: .merchantContains("REWE"), categoryID: UUID())
        ])

        let context = ModelContext(store.container)
        let rows = try context.fetch(FetchDescriptor<SDRuleEntity>())
        #expect(rows.count == 1)
        rows[0].conditionTypeRaw = "future_unknown_type"
        try context.save()

        await #expect(throws: PersistenceDecodingError.self) {
            _ = try await dependencies.ruleRepository.rules()
        }
    }
    @Test("Wiederkehrende Zahlungen maskieren keine unbekannten Enum-Werte")
    func recurringEnumsAreStrict() throws {
        for field in ["direction", "cadence", "amountPolicy", "status", "origin"] {
            let entity = SDRecurringCommitmentEntity(from: RecurringCommitment(
                name: "Abo", expectedAmount: 10))
            switch field {
            case "direction": entity.directionRaw = "corrupt"
            case "cadence": entity.cadenceRaw = "corrupt"
            case "amountPolicy": entity.amountPolicyRaw = "corrupt"
            case "status": entity.statusRaw = "corrupt"
            default: entity.originRaw = "corrupt"
            }
            #expect(throws: PersistenceDecodingError.unknownEnum(field: "recurring." + field, raw: "corrupt")) {
                try entity.toDomain()
            }
        }
    }

}
