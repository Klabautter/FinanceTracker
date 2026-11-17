import Foundation
import Testing

@testable import FinanceTracker

/// Kontostände und Prüfzahl der Übersicht entstehen Scheibe für Scheibe
/// (Roadmap 3.8: Speicher bei großen Beständen). Sie müssen genau dem
/// Ergebnis über alle Buchungen auf einmal entsprechen, auch wenn der
/// Bestand wirklich in mehreren Scheiben gelesen wird.
@MainActor
@Suite("Übersicht: Stände und Prüfzahl in Scheiben")
struct WholeStoreFiguresTests {
    @Test("Gestreamte Stände und Prüfzahl gleichen dem Gesamtpfad")
    func streamedFiguresMatchWholeStore() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 12)))
        let openingDate = try #require(calendar.date(byAdding: .day, value: -400, to: now))
        let giro = Account(
            name: "Giro", type: .checking, currency: .eur, source: .manual,
            openingBalance: 1_000, openingBalanceDate: openingDate
        )
        let savings = Account(name: "Tagesgeld", type: .savings, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([giro, savings])

        // Mehr als zwei Scheiben, damit wirklich in Teilen gelesen wird.
        let count = LocalTransactionRepository.lightRowSliceSize * 2 + 700
        var rows: [Transaction] = []
        for index in 0..<count {
            let date = calendar.date(byAdding: .hour, value: -index * 3, to: now)
            switch index % 10 {
            case 0:
                // Mögliche Umbuchung Giro → Tagesgeld, Gegenstück am selben Tag.
                rows.append(Transaction(
                    accountID: giro.id, source: .manual, externalID: "t\(index)",
                    status: .booked, kind: .purchase,
                    amount: Money(amount: -Decimal(index % 50 + 10), currency: .eur),
                    bookedAt: date, rawDescription: "Übertrag \(index)"
                ))
                rows.append(Transaction(
                    accountID: savings.id, source: .manual, externalID: "c\(index)",
                    status: .booked, kind: .transfer,
                    amount: Money(amount: Decimal(index % 50 + 10), currency: .eur),
                    bookedAt: date, rawDescription: "Eingang \(index)"
                ))
            case 1:
                rows.append(Transaction(
                    accountID: giro.id, source: .manual, externalID: "p\(index)",
                    status: .pending, kind: .purchase,
                    amount: Money(amount: -5, currency: .eur),
                    bookedAt: date, rawDescription: "Vorgemerkt"
                ))
            case 2:
                rows.append(Transaction(
                    accountID: giro.id, source: .manual, externalID: "f\(index)",
                    status: .booked, kind: .purchase,
                    amount: Money(amount: -12, currency: .usd),
                    bookedAt: date, rawDescription: "Fremdwährung"
                ))
            default:
                rows.append(Transaction(
                    accountID: index % 3 == 0 ? savings.id : giro.id, source: .manual, externalID: "k\(index)",
                    status: .booked, kind: .purchase,
                    amount: Money(amount: -(Decimal(index % 90) + Decimal(index % 100) / 100 + 1), currency: .eur),
                    bookedAt: date, rawMerchantName: index % 4 == 0 ? nil : "Laden \(index % 30)",
                    categoryID: index % 5 == 0 ? Category.transfers.id : nil
                ))
            }
        }
        try await dependencies.transactionRepository.upsert(rows)
        // Ein Teil ist geprüft, einer hat einen manuellen Typ.
        try await dependencies.transactionAnnotationRepository.upsert(rows.enumerated().compactMap { index, row in
            switch index % 7 {
            case 0: TransactionAnnotation(transactionID: row.id, reviewed: true)
            case 3: TransactionAnnotation(transactionID: row.id, manualKindOverride: .transfer)
            default: nil
            }
        })

        // Erwartung: der bisherige Pfad über alle Buchungen auf einmal.
        let all = try await dependencies.transactionRepository.reviewCandidateTransactions()
        #expect(all.count == rows.count)
        #expect(Set(all.map(\.id)).count == rows.count)
        let effective = EffectiveTransactionResolver().applying(
            annotations: try await dependencies.transactionAnnotationRepository.annotations(),
            to: all
        )
        let converter = await dependencies.fxRateProvider.converter()
        let expectedSummary = ReviewQueueBuilder().buildSummary(
            transactions: effective,
            baseCurrency: .eur,
            accountCurrencies: [giro.id: .eur, savings.id: .eur],
            converter: converter,
            calendar: calendar
        )
        let expectedBalances = try await LoadAccountBalances(
            accountRepository: dependencies.accountRepository,
            transactionRepository: dependencies.transactionRepository
        ).execute(converter: converter, calendar: calendar, knownMovements: all.map(AccountMovementRow.init(transaction:)))
        let expectedLiquidity = LiquidityCalculator(baseCurrency: .eur, converter: converter)
            .overview(of: expectedBalances.active)

        let model = DashboardModel(dependencies: dependencies, calendar: calendar, now: { now })
        await model.load()

        #expect(expectedSummary.totalCount > 0)
        #expect(expectedSummary.transferCandidateCount > 0)
        #expect(model.reviewSummary == expectedSummary)
        #expect(!expectedLiquidity.shares.isEmpty)
        #expect(model.liquidity == expectedLiquidity)
    }
}
