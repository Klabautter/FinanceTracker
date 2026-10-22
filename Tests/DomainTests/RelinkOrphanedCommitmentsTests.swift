import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("Fixkosten eines gelöschten Kontos")
struct RelinkOrphanedCommitmentsTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func useCase(_ dependencies: AppDependencies) -> RelinkOrphanedCommitments {
        RelinkOrphanedCommitments(
            commitmentRepository: dependencies.recurringCommitmentRepository,
            accountRepository: dependencies.accountRepository,
            transactionRepository: dependencies.transactionRepository
        )
    }

    private func rent(on accountID: UUID, merchantID: UUID) -> Transaction {
        Transaction(
            accountID: accountID, source: .openBanking, kind: .purchase,
            amount: Money(amount: -579, currency: .eur),
            bookedAt: Date(), rawMerchantName: "urban homes", merchantID: merchantID,
            merchantDisplayName: "urban homes"
        )
    }

    @Test("Fixkost wird auf das einzige Konto mit den Händler-Buchungen umgehängt")
    func relinksToRemainingAccount() async throws {
        let dependencies = try makeDependencies()
        let remaining = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([remaining])
        let merchantID = UUID()
        try await dependencies.transactionRepository.upsert([rent(on: remaining.id, merchantID: merchantID)])
        let deletedAccountID = UUID()
        let commitment = RecurringCommitment(
            name: "Miete",
            merchantKey: RecurringMerchantIdentity(accountID: deletedAccountID, merchantKey: merchantID.uuidString).persistedKey,
            expectedAmount: 579,
            origin: .confirmedDetection
        )
        try await dependencies.recurringCommitmentRepository.upsert([commitment])

        let outcome = try await useCase(dependencies).run()

        #expect(outcome.relinkedCount == 1)
        #expect(outcome.orphanedIDs.isEmpty)
        let stored = try #require(await dependencies.recurringCommitmentRepository.commitment(id: commitment.id))
        #expect(stored.matchingAccountID == remaining.id)
        #expect(stored.matchingMerchantKey == merchantID.uuidString)
        // Zweiter Lauf ändert nichts mehr.
        #expect(try await useCase(dependencies).run() == .init())
    }

    @Test("Mehrdeutig oder ohne Buchungen: bleibt unverändert und gilt als verwaist")
    func ambiguousStaysOrphaned() async throws {
        let dependencies = try makeDependencies()
        let first = Account(name: "A", type: .checking, currency: .eur, source: .openBanking)
        let second = Account(name: "B", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([first, second])
        let merchantID = UUID()
        try await dependencies.transactionRepository.upsert([
            rent(on: first.id, merchantID: merchantID),
            rent(on: second.id, merchantID: merchantID)
        ])
        let key = RecurringMerchantIdentity(accountID: UUID(), merchantKey: merchantID.uuidString).persistedKey
        let ambiguous = RecurringCommitment(name: "Miete", merchantKey: key, expectedAmount: 579)
        let unknown = RecurringCommitment(
            name: "Weg",
            merchantKey: RecurringMerchantIdentity(accountID: UUID(), merchantKey: UUID().uuidString).persistedKey,
            expectedAmount: 10
        )
        let manual = RecurringCommitment(name: "Manuell", expectedAmount: 5)
        try await dependencies.recurringCommitmentRepository.upsert([ambiguous, unknown, manual])

        let outcome = try await useCase(dependencies).run()

        #expect(outcome.relinkedCount == 0)
        #expect(outcome.orphanedIDs == [ambiguous.id, unknown.id])
        #expect(try await dependencies.recurringCommitmentRepository.commitment(id: ambiguous.id)?.merchantKey == key)
    }
}
