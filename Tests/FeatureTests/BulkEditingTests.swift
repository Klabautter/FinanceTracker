import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("BulkEditing")
struct BulkEditingTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func makeModel(_ dependencies: AppDependencies) -> TransactionsModel {
        TransactionsModel(dependencies: dependencies)
    }

    private func seedTransactions(_ dependencies: AppDependencies, count: Int) async throws -> [Transaction] {
        try await dependencies.accountRepository.upsert([
            Account(name: "Bulk Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        var transactions: [Transaction] = []
        for index in 0..<count {
            transactions.append(Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: "bulk-\(index)",
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -Decimal(index + 1), currency: .eur),
                bookedAt: Date(),
                rawDescription: "REWE \(index)",
                rawMerchantName: "REWE",
                merchantDisplayName: "REWE"
            ))
        }
        try await dependencies.transactionRepository.upsert(transactions)
        return transactions
    }

    @Test("Bulk-Kategorie setzt Kategorie für alle Ziele")
    func bulkChangeCategory() async throws {
        let dependencies = try makeDependencies()
        let model = makeModel(dependencies)
        let seeded = try await seedTransactions(dependencies, count: 3)

        await model.refresh()
        let targets = Set(seeded.map(\.id))
        await model.bulkChangeCategory(nil, for: targets)

        let rows = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        for row in rows {
            #expect(row.categoryID == nil)
        }
    }

    @Test("Bulk-Reviewed setzt Annotationen für alle Ziele")
    func bulkToggleReviewed() async throws {
        let dependencies = try makeDependencies()
        let model = makeModel(dependencies)
        let seeded = try await seedTransactions(dependencies, count: 3)

        await model.refresh()
        let targets = Set(seeded.map(\.id))
        await model.bulkToggleReviewed(true, for: targets)

        let annotations = try await dependencies.transactionAnnotationRepository.annotations()
        #expect(annotations.count == 3)
        for annotation in annotations {
            #expect(annotation.reviewed)
        }
    }

    @Test("Bulk-Tag hinzufügen/entfernen über Annotationen")
    func bulkTags() async throws {
        let dependencies = try makeDependencies()
        let model = makeModel(dependencies)
        let seeded = try await seedTransactions(dependencies, count: 2)

        let tag = Tag(name: "Urlaub", colorToken: .blue)
        try await dependencies.tagRepository.upsert([tag])

        await model.refresh()
        let targets = Set(seeded.map(\.id))
        await model.bulkAddTag(tag.id, for: targets)

        var annotations = try await dependencies.transactionAnnotationRepository.annotations()
        #expect(annotations.count == 2)
        for annotation in annotations {
            #expect(annotation.tagIDs?.contains(tag.id) == true)
        }

        await model.bulkRemoveTag(tag.id, for: targets)
        annotations = try await dependencies.transactionAnnotationRepository.annotations()
        for annotation in annotations {
            #expect(annotation.tagIDs?.contains(tag.id) != true)
        }
    }

    @Test("Bulk mit leerer Auswahl ändert nichts")
    func bulkEmptySelection() async throws {
        let dependencies = try makeDependencies()
        let model = makeModel(dependencies)
        let seeded = try await seedTransactions(dependencies, count: 2)

        await model.refresh()
        await model.bulkToggleReviewed(true, for: [])
        await model.bulkChangeCategory(nil, for: [])

        let annotations = try await dependencies.transactionAnnotationRepository.annotations()
        #expect(annotations.isEmpty)

        let rows = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        #expect(rows.count == seeded.count)
    }
}
