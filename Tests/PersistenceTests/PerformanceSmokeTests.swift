import Foundation
import Testing

@testable import FinanceTracker

@Suite("PerformanceSmoke", .serialized)
struct PerformanceSmokeTests {
    private let targetCount = 10_000

    @Test("10.000 Transaktionen: Dashboard-Pfad und Analytics bleiben schnell")
    func scaleTenThousand() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        try await dependencies.accountRepository.upsert([
            Account(name: "Perf Giro", type: .checking, currency: .eur, source: .csvImport),
            Account(name: "Perf Card", type: .creditCard, currency: .eur, source: .csvImport)
        ])
        let giroID = try #require(await dependencies.accountRepository.accounts().first?.id)

        let clock = ContinuousClock()
        var generated: [Transaction] = []
        generated.reserveCapacity(targetCount)

        let calendar = Calendar(identifier: .gregorian)
        let merchants = ["REWE", "BILLA", "SPAR DANKT 1234", "AMZN MKTP DE*99", "SHELL 4711", "SPOTIFY AB"]
        let kinds: [TransactionKind] = [.purchase, .purchase, .purchase, .refund, .fee]

        for index in 0..<targetCount {
            let dayOffset = index % 365
            let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let merchant = merchants[index % merchants.count]
            let kind = kinds[index % kinds.count]
            let amountCents = Decimal((index % 9_000) + 100) / 100

            generated.append(Transaction(
                id: UUID(),
                accountID: giroID,
                source: .genericCSV,
                externalID: "perf-\(index)",
                status: .booked,
                kind: kind,
                amount: Money(amount: -amountCents, currency: .eur),
                bookedAt: date,
                rawDescription: "\(merchant) \(index)",
                rawMerchantName: merchant,
                merchantDisplayName: merchant,
                paymentMethod: .cardPresent
            ))
        }

        let insertDuration = try await clock.measure {
            for start in stride(from: 0, to: generated.count, by: 500) {
                let slice = Array(generated[start..<Swift.min(start + 500, generated.count)])
                try await dependencies.transactionRepository.upsert(slice)
            }
        }

        #expect(try await dependencies.transactionRepository.count() == targetCount)

        let dashboardFetchDuration = try await clock.measure {
            _ = try await dependencies.transactionRepository.transactionPage(
                matching: queryForLastMonths(3), sort: .dateDescending, offset: 0, limit: 200
            )
        }

        let analyticsDuration = try await clock.measure {
            let all = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
            let calculator = AnalyticsCalculator(baseCurrency: .eur)
            _ = calculator.snapshot(transactions: all, categories: [], calendar: .current)
            _ = calculator.monthlyPoints(transactions: all, monthsBack: 12, calendar: .current)
        }

        print("PERF 10k, insert: \(insertDuration), scoped fetch: \(dashboardFetchDuration), full+analytics: \(analyticsDuration)")

        #expect(dashboardFetchDuration < .seconds(5))
        #expect(analyticsDuration < .seconds(10))
    }

    private func queryForLastMonths(_ months: Int) -> TransactionQuery {
        let calendar = Calendar.current
        let now = Date()
        guard let currentStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let start = calendar.date(byAdding: .month, value: -(months - 1), to: currentStart),
              let end = calendar.date(byAdding: .month, value: 1, to: currentStart) else {
            return TransactionQuery()
        }
        var query = TransactionQuery()
        query.dateInterval = DateInterval(start: start, end: end)
        return query
    }

    @Test("50.000 Transaktionen: Pfad-Zerlegung für Analytics und gefilterte Loads")
    func scaleFiftyThousandSplit() async throws {
        let clock = ContinuousClock()
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)

        try await dependencies.accountRepository.upsert([
            Account(name: "Perf Giro A", type: .checking, currency: .eur, source: .csvImport),
            Account(name: "Perf Card B", type: .creditCard, currency: .eur, source: .csvImport)
        ])
        let accounts = try #require(await dependencies.accountRepository.accounts())
        let giroID = try #require(accounts.first(where: { $0.name == "Perf Giro A" })?.id)
        let cardID = try #require(accounts.first(where: { $0.name == "Perf Card B" })?.id)

        let calendar = Calendar(identifier: .gregorian)
        let targetCount = 50_000
        var generated: [Transaction] = []
        generated.reserveCapacity(targetCount)
        let merchants = ["REWE", "BILLA", "SPAR DANKT 1234", "AMZN MKTP DE*99", "SHELL 4711", "SPOTIFY AB"]
        let kinds: [TransactionKind] = [.purchase, .purchase, .purchase, .refund, .fee]

        for index in 0..<targetCount {
            let dayOffset = index % 730
            let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let merchant = merchants[index % merchants.count]
            let kind = kinds[index % kinds.count]
            let amountCents = Decimal((index % 9_000) + 100) / 100
            generated.append(Transaction(
                id: UUID(),
                accountID: index % 2 == 0 ? giroID : cardID,
                source: .genericCSV,
                externalID: "perf50-\(index)",
                status: .booked,
                kind: kind,
                amount: Money(amount: -amountCents, currency: .eur),
                bookedAt: date,
                rawDescription: "\(merchant) \(index)",
                rawMerchantName: merchant,
                merchantDisplayName: merchant,
                paymentMethod: .cardPresent
            ))
        }

        let insertDuration = try await clock.measure {
            for start in stride(from: 0, to: generated.count, by: 1_000) {
                let slice = Array(generated[start..<Swift.min(start + 1_000, generated.count)])
                try await dependencies.transactionRepository.upsert(slice)
            }
        }

        let calculator = AnalyticsCalculator(baseCurrency: .eur)
        let detector = RecurringPaymentsDetector()
        let allQuery = TransactionQuery()
        let intervalQuery = queryForLastMonths(12)

        let fetchAllDuration = try await clock.measure {
            _ = try await dependencies.transactionRepository.transactions(matching: allQuery)
        }

        let fetchIntervalDuration = try await clock.measure {
            _ = try await dependencies.transactionRepository.transactions(matching: intervalQuery)
        }

        let accountFilterDuration = try await clock.measure {
            // Reproduziert den aktuellen Analytics-Pfad mit Account-Filter:
            // Voll-Load + in-memory refine.
            let all = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
            var filtered = intervalQuery
            filtered.accountIDs = [giroID]
            _ = all.filter { filtered.matches($0) }
        }

        let annotationsDuration = try await clock.measure {
            let all = try await dependencies.transactionRepository.transactions(matching: intervalQuery)
            let ids = Set(all.map(\.id))
            _ = try await dependencies.transactionAnnotationRepository.annotations(transactionIDs: ids)
        }

        let detectorDuration = try await clock.measure {
            let all = try await dependencies.transactionRepository.transactions(matching: intervalQuery)
            _ = detector.detect(transactions: all, calendar: .current)
        }

        let calculatorDuration = try await clock.measure {
            let all = try await dependencies.transactionRepository.transactions(matching: intervalQuery)
            _ = calculator.snapshot(transactions: all, categories: [], calendar: .current)
            _ = calculator.monthlyPoints(transactions: all, monthsBack: 12, calendar: .current)
        }

        let combinedAnalyticsDuration = try await clock.measure {
            let all = try await dependencies.transactionRepository.transactions(matching: intervalQuery)
            _ = try await dependencies.transactionAnnotationRepository.annotations(transactionIDs: Set(all.map(\.id)))
            _ = detector.detect(transactions: all, calendar: .current)
            _ = calculator.snapshot(transactions: all, categories: [], calendar: .current)
            _ = calculator.monthlyPoints(transactions: all, monthsBack: 12, calendar: .current)
        }

        print("PERF 50k, insert: \(insertDuration)")
        print("PERF 50k, fetch ALL: \(fetchAllDuration), fetch 12M interval: \(fetchIntervalDuration), account-filter (Voll-Load+refine): \(accountFilterDuration)")
        print("PERF 50k, annotation resolve: \(annotationsDuration), recurring detector: \(detectorDuration), calculator: \(calculatorDuration)")
        print("PERF 50k, analytics kombiniert (12M): \(combinedAnalyticsDuration)")

        #expect(try await dependencies.transactionRepository.count() == targetCount)
    }
}

private extension ContinuousClock {
    func measure(_ work: () async throws -> Void) async rethrows -> Duration {
        let start = now
        try await work()
        return now - start
    }
}
