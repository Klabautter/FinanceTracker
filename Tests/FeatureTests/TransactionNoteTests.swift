import Foundation
import Testing

@testable import FinanceTracker

/// Notiz zu einer Bankbuchung: bleibt Nutzer-Metadatum (Annotation), ist
/// rückgängig machbar und über die Suche auffindbar.
@MainActor
@Suite("Notiz an Buchungen")
struct TransactionNoteTests {
    @Test("Notiz speichern, suchen, rückgängig machen")
    func noteRoundTrip() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([account])
        let transfer = Transaction(
            accountID: account.id, source: .openBanking, externalID: "x", kind: .purchase,
            amount: Money(amount: -200, currency: .eur), bookedAt: Date(),
            rawDescription: "Überweisung", rawMerchantName: "Erika Mustermann", merchantDisplayName: "Erika Mustermann"
        )
        try await dependencies.transactionRepository.upsert([transfer])

        let model = TransactionsModel(dependencies: dependencies)
        await model.refresh()
        let loaded = try #require(model.transaction(withID: transfer.id))
        await model.updateNote(loaded, note: "Grafikkarte von Erika")

        #expect(model.transaction(withID: transfer.id)?.note == "Grafikkarte von Erika")
        // Provider-Fakt bleibt unverändert, die Notiz liegt in der Annotation.
        #expect(try await dependencies.transactionRepository.transaction(id: transfer.id)?.note == nil)
        #expect(try await dependencies.transactionAnnotationRepository.annotation(transactionID: transfer.id)?.note == "Grafikkarte von Erika")

        var query = TransactionQuery()
        query.searchText = "grafikkarte"
        let page = try await dependencies.transactionRepository.transactionPage(
            matching: query, sort: .dateDescending, offset: 0, limit: 10
        )
        #expect(page.transactions.map(\.id) == [transfer.id])

        await model.undo()
        #expect(model.transaction(withID: transfer.id)?.note == nil)
    }
}
