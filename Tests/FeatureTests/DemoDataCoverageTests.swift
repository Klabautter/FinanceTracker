import Foundation
import Testing

@testable import FinanceTracker

/// Der Demo-Datensatz ist die Grundlage für UI/UX-Durchläufe und
/// README-Screenshots. Er muss die Zustände enthalten, in denen Layoutfehler
/// sichtbar werden; fehlt einer, fällt ein Fehler dort nie auf.
@Suite("DemoDataCoverage")
struct DemoDataCoverageTests {
    private let data = DemoDataFactory.make()

    @Test("Buchungen: vorgemerkt, ohne Kategorie, Fremdwährung, Einnahme, Bargeld")
    func transactionStates() {
        let transactions = data.transactions
        #expect(transactions.contains { $0.status == .pending })
        #expect(transactions.contains { $0.categoryID == nil })
        #expect(transactions.contains { $0.amount.currency != .eur })
        #expect(transactions.contains { $0.amount.amount > 0 })
        #expect(transactions.contains { $0.paymentMethod == .cash })
    }

    @Test("Wiederkehrend: bestätigte Zahlungspläne und mehrere offene Vorschläge")
    func recurringStates() {
        #expect(data.commitments.contains { $0.direction == .expense })
        #expect(data.commitments.contains { $0.direction == .income })
        let confirmed = Set(data.commitments.compactMap(\.merchantKey))
        let detected = RecurringPaymentsDetector().detect(transactions: data.transactions)
        let suggestions = detected.filter {
            !confirmed.contains(RecurringMerchantIdentity(accountID: $0.accountID, merchantKey: $0.merchantKey).persistedKey)
        }
        // Bestätigte Zahlungspläne tauchen nicht zusätzlich als Vorschlag auf.
        #expect(detected.count - suggestions.count == 1)
        // Mindestens zwei: einer lässt sich im UI-Durchlauf ausblenden,
        // der andere bleibt als offener Vorschlag sichtbar.
        #expect(suggestions.count >= 2)
    }

    @Test("Budgets und Sammlungen in verschiedenen Zuständen")
    func planningStates() {
        #expect(data.budgets.count >= 2)
        let now = Date()
        let collections = data.transactionCollections
        #expect(collections.contains { $0.startDate <= now && now < $0.endDateExclusive })
        #expect(collections.contains { $0.startDate > now })
        #expect(collections.contains { $0.endDateExclusive <= now })
    }

    @Test("Kontostände: Bank heute, älterer Auszug, Anfangsbestand, Fremdwährung, ohne Stand")
    func balanceStates() {
        let accounts = data.accounts
        let now = Date()
        #expect(accounts.contains { $0.reportedBalance?.source == .bank && now.timeIntervalSince($0.reportedBalance!.asOf) < 86_400 })
        #expect(accounts.contains { $0.reportedBalance?.source == .file && now.timeIntervalSince($0.reportedBalance!.asOf) > 3 * 86_400 })
        #expect(accounts.contains { $0.openingBalance != nil })
        #expect(accounts.contains { $0.reportedBalance != nil && $0.currency != .eur })
        #expect(accounts.contains { $0.reportedBalance == nil && $0.openingBalance == nil })
        #expect(accounts.contains { ($0.reportedBalance?.amount.amount ?? 0) < 0 })
    }
}
