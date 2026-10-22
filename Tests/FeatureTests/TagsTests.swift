import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("Tags")
struct TagsTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func sampleTransaction(_ dependencies: AppDependencies, accountID: UUID, index: Int) -> Transaction {
        Transaction(
            id: UUID(),
            accountID: accountID,
            source: .demo,
            externalID: "tag-test-\(index)",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(index + 1), currency: .eur),
            bookedAt: Date(),
            rawDescription: "REWE \(index)",
            rawMerchantName: "REWE",
            merchantDisplayName: "REWE"
        )
    }

    @Test("Tag CRUD: erstellen, laden, umbenennen, Farbe ändern")
    func tagCRUD() async throws {
        let dependencies = try makeDependencies()

        let tag = Tag(name: "Urlaub 2026", colorToken: .teal)
        try await dependencies.tagRepository.upsert([tag])

        var loaded = try await dependencies.tagRepository.tags()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Urlaub 2026")
        #expect(loaded.first?.colorToken == .teal)

        var updated = tag
        updated.name = "Urlaub Italien"
        updated.colorToken = .purple
        try await dependencies.tagRepository.upsert([updated])

        loaded = try await dependencies.tagRepository.tags()
        #expect(loaded.first?.name == "Urlaub Italien")
        #expect(loaded.first?.colorToken == .purple)
    }

    @Test("Tag löschen entfernt tagID aus Annotationen, Transaktionen bleiben")
    func deleteRemovesTagFromAnnotations() async throws {
        let dependencies = try makeDependencies()

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let txn1 = sampleTransaction(dependencies, accountID: account.id, index: 1)
        let txn2 = sampleTransaction(dependencies, accountID: account.id, index: 2)
        try await dependencies.transactionRepository.upsert([txn1, txn2])

        let tag = Tag(name: "Dienstlich", colorToken: .indigo)
        try await dependencies.tagRepository.upsert([tag])

        var annotation1 = TransactionAnnotation(
            transactionID: txn1.id,
            reviewed: false,
            excludedFromAnalytics: false
        )
        annotation1.tagIDs = [tag.id]
        var annotation2 = TransactionAnnotation(
            transactionID: txn2.id,
            reviewed: false,
            excludedFromAnalytics: false
        )
        annotation2.tagIDs = [tag.id]
        try await dependencies.transactionAnnotationRepository.upsert([annotation1, annotation2])

        // Tag löschen
        try await dependencies.tagRepository.delete(id: tag.id)
        #expect(try await dependencies.tagRepository.tags().isEmpty)

        // Orphan-Cleanup: Annotationen haben die tagID nicht mehr
        let resolvedAnnotations = try await dependencies.transactionAnnotationRepository.annotations()
        #expect(resolvedAnnotations.count == 2)
        for annotation in resolvedAnnotations {
            #expect(annotation.tagIDs?.contains(tag.id) != true)
        }

        // Transaktionen bleiben unverändert
        #expect(try await dependencies.transactionRepository.count() == 2)
    }

    @Test("Annotations-Fetch ohne IDs liefert alle Annotationen")
    func fetchAllAnnotations() async throws {
        let dependencies = try makeDependencies()

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        let txn = sampleTransaction(dependencies, accountID: account.id, index: 1)
        try await dependencies.transactionRepository.upsert([txn])

        var annotation = TransactionAnnotation(
            transactionID: txn.id,
            reviewed: true,
            excludedFromAnalytics: false
        )
        annotation.note = "Notiz"
        try await dependencies.transactionAnnotationRepository.upsert([annotation])

        let all = try await dependencies.transactionAnnotationRepository.annotations()
        #expect(all.count == 1)
        #expect(all.first?.note == "Notiz")
    }

    @Test("EffectiveTransactionResolver übernimmt tagIDs aus Annotation")
    func resolverCarriesTagIDs() async throws {
        let tag = Tag(name: "Italien", colorToken: .blue)
        let resolver = EffectiveTransactionResolver()

        let txn = Transaction(
            accountID: UUID(),
            source: .demo,
            externalID: "x1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(10), currency: .eur),
            bookedAt: Date()
        )

        var annotation = TransactionAnnotation.legacyFallback(for: txn)
        annotation.tagIDs = [tag.id]

        let effective = resolver.applying(annotation: annotation, to: txn)
        #expect(effective.tagIDs == [tag.id])
    }
}

// MARK: - Tag-Filter (Roadmap #16, ANY-Semantik)

@MainActor
@Suite("TagFilter")
struct TagFilterTests {
    @Test("visibleTransactions filtert ANY über effektive tagIDs")
    func anySemantics() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let model = TransactionsModel(dependencies: dependencies)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let tagItalien = Tag(name: "Italien", colorToken: .blue)
        let tagDienstlich = Tag(name: "Dienstlich", colorToken: .green)
        try await dependencies.tagRepository.upsert([tagItalien, tagDienstlich])

        func txn(_ id: String) -> Transaction {
            Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: id,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -Decimal(10), currency: .eur),
                bookedAt: Date(),
                rawDescription: id,
                rawMerchantName: id,
                merchantDisplayName: id
            )
        }
        let rows = [txn("a"), txn("b"), txn("c")]
        try await dependencies.transactionRepository.upsert(rows)

        var annA = TransactionAnnotation.legacyFallback(for: rows[0])
        annA.tagIDs = [tagItalien.id]
        var annC = TransactionAnnotation.legacyFallback(for: rows[2])
        annC.tagIDs = [tagDienstlich.id, tagItalien.id]
        try await dependencies.transactionAnnotationRepository.upsert([annA, annC])

        await model.refresh()
        #expect(model.visibleTransactions.count == 3)

        model.filterTagIDs = [tagItalien.id]
        #expect(model.visibleTransactions.count == 2)
        let visibleIDs = Set(model.visibleTransactions.compactMap(\.externalID))
        #expect(visibleIDs == ["a", "c"])

        model.filterTagIDs = [tagDienstlich.id]
        #expect(model.visibleTransactions.count == 1)
        #expect(model.visibleTransactions.first?.externalID == "c")
    }
}


@MainActor
@Suite("TagFilterMode")
struct TagFilterModeTests {
    @Test("ALL-Modus verlangt alle gewählten Tags, ANY nur eines")
    func anyVsAll() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let model = TransactionsModel(dependencies: dependencies)

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)

        let tagA = Tag(name: "A", colorToken: .blue)
        let tagB = Tag(name: "B", colorToken: .green)
        try await dependencies.tagRepository.upsert([tagA, tagB])

        func txn(_ id: String, _ tagIDs: [UUID]) -> Transaction {
            Transaction(
                id: UUID(),
                accountID: account.id,
                source: .demo,
                externalID: id,
                status: .booked,
                kind: .purchase,
                amount: Money(amount: -Decimal(1), currency: .eur),
                bookedAt: Date(),
                rawDescription: id,
                rawMerchantName: id,
                merchantDisplayName: id,
                tagIDs: tagIDs
            )
        }
        try await dependencies.transactionRepository.upsert([
            txn("a+b", [tagA.id, tagB.id]),
            txn("nur-a", [tagA.id]),
            txn("ohne", [])
        ])

        await model.refresh()
        model.filterTagIDs = [tagA.id, tagB.id]

        model.tagFilterMode = .any
        #expect(model.visibleTransactions.count == 2)

        model.tagFilterMode = .all
        #expect(model.visibleTransactions.count == 1)
        #expect(model.visibleTransactions.first?.externalID == "a+b")
    }
}
