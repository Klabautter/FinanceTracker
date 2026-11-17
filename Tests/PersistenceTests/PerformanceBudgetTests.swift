import Foundation
import Testing

@testable import FinanceTracker

/// Leistungsbudget (Roadmap 3.8) als normaler Test: 20.000 Buchungen auf
/// einem Datenträger-Store. Die Grenzen gelten für den langsamen Debug-Build
/// mit Reserve; reißt eine, ist ein Pfad deutlich langsamer geworden.
/// Gemessen am 17.11.2026 (50.000 Buchungen, Debug): erstes Laden der
/// Übersicht 2,4 s, Monatswechsel 0,06 s, erste Transaktionsseite 0,012 s.
@MainActor
@Suite("PerformanceBudget", .serialized)
struct PerformanceBudgetTests {
    @Test("Übersicht, Monatswechsel und Transaktionsseite bleiben im Budget", .timeLimit(.minutes(2)))
    func staysWithinBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perf-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataStore(url: directory.appendingPathComponent("budget.store"))
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        let calendar = Calendar.current
        let now = Date()
        var rows: [Transaction] = []
        rows.reserveCapacity(20_000)
        for index in 0..<20_000 {
            rows.append(Transaction(
                accountID: account.id, source: .manual, externalID: "b\(index)", status: .booked, kind: .purchase,
                amount: Money(amount: -Decimal(index % 300 + 1), currency: .eur),
                bookedAt: calendar.date(byAdding: .hour, value: -index * 3, to: now),
                rawDescription: "Händler \(index % 400)", rawMerchantName: "Händler \(index % 400)",
                merchantDisplayName: "Händler \(index % 400)"
            ))
        }
        for start in stride(from: 0, to: rows.count, by: 2_000) {
            try await dependencies.transactionRepository.upsert(Array(rows[start..<min(start + 2_000, rows.count)]))
        }

        let clock = ContinuousClock()
        let model = DashboardModel(dependencies: dependencies)
        let firstLoad = await clock.measure { await model.load() }
        let monthSwitch = await clock.measure { await model.showPreviousMonth() }
        let firstPage = try await clock.measure {
            _ = try await dependencies.transactionRepository.transactionPage(
                matching: TransactionQuery(), sort: .dateDescending, offset: 0, limit: 300
            )
        }
        print("PERF budget 20k: first load \(firstLoad), month switch \(monthSwitch), first page \(firstPage)")

        #expect(model.snapshot != nil)
        #expect(firstLoad < .seconds(4))
        #expect(monthSwitch < .milliseconds(500))
        #expect(firstPage < .milliseconds(300))
    }
}
