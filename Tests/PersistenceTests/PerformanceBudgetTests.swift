import Foundation
import Testing

@testable import FinanceTracker

/// Leistungsbudget (Roadmap 3.8) als normaler Test: 100.000 Buchungen auf
/// fünf Konten (mit Umbuchungen) in einem Datenträger-Store, dazu ein
/// Import von 20.000 CSV-Zeilen. Die Grenzen gelten für den langsamen
/// Debug-Build mit Reserve (ein Release-Testhost läuft auf macOS 26 nicht);
/// reißt eine, ist ein Pfad deutlich langsamer geworden. Messwerte stehen
/// in der Testausgabe (`PERF budget 100k`).
@MainActor
@Suite("PerformanceBudget", .serialized)
struct PerformanceBudgetTests {
    @Test("100.000 Buchungen: Übersicht, Monatswechsel, Seite, Suche und Import bleiben im Budget", .timeLimit(.minutes(5)))
    func staysWithinBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perf-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataStore(url: directory.appendingPathComponent("budget.store"))
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let accounts = (0..<5).map { Account(name: "Konto \($0)", type: .checking, currency: .eur, source: .manual) }
        try await dependencies.accountRepository.upsert(accounts)
        let calendar = Calendar.current
        let now = Date()
        var rows: [Transaction] = []
        rows.reserveCapacity(100_000)
        for index in 0..<100_000 {
            // Jede siebte Zeile ist ein Eingang, damit die Umbuchungs-
            // erkennung echte Kandidaten zu prüfen hat.
            let incoming = index % 7 == 0
            let value = Decimal(index % 300 + 1) + Decimal(index % 100) / 100
            rows.append(Transaction(
                accountID: accounts[(index * 3 + index / 5) % 5].id, source: .manual, externalID: "b\(index)",
                status: .booked, kind: incoming ? .transfer : .purchase,
                amount: Money(amount: incoming ? value : -value, currency: .eur),
                bookedAt: calendar.date(byAdding: .minute, value: -index * 40, to: now),
                rawDescription: "Händler \(index % 400)", rawMerchantName: "Händler \(index % 400)",
                merchantDisplayName: "Händler \(index % 400)"
            ))
        }
        for start in stride(from: 0, to: rows.count, by: 5_000) {
            try await dependencies.transactionRepository.upsert(Array(rows[start..<min(start + 5_000, rows.count)]))
        }

        // Optional: den 100k-Store für den Rauchtest des Release-Builds
        // ablegen (Scripts/smoke-test-app.sh --store), keine echten Daten.
        if let export = ProcessInfo.processInfo.environment["PERF_EXPORT_STORE"] {
            let target = URL(fileURLWithPath: export)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = directory.appendingPathComponent("budget.store")
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: source.path + suffix) {
                try? FileManager.default.removeItem(atPath: target.path + suffix)
                try FileManager.default.copyItem(atPath: source.path + suffix, toPath: target.path + suffix)
            }
        }

        // Ab 20.000 Zeilen liest das Repository parallel in Zeitscheiben:
        // jede Buchung genau einmal.
        let lightRows = try await dependencies.transactionRepository.reviewCandidateTransactions()
        #expect(lightRows.count == rows.count)
        #expect(Set(lightRows.map(\.id)) == Set(rows.map(\.id)))

        let clock = ContinuousClock()
        let model = DashboardModel(dependencies: dependencies)
        let (firstVisible, firstLoad) = await model.measureLoad()
        // Der Vormonat wird vorbereitet, sobald die Übersicht steht; zurück
        // zum laufenden Monat lädt ohne Vorbereitung.
        await model.waitForPreparedMonth()
        let monthSwitch = await clock.measure { await model.showPreviousMonth() }
        let unpreparedMonthSwitch = await clock.measure { await model.showNextMonth() }
        let firstPage = try await clock.measure {
            _ = try await dependencies.transactionRepository.transactionPage(
                matching: TransactionQuery(), sort: .dateDescending, offset: 0, limit: 300
            )
        }
        var searchQuery = TransactionQuery()
        searchQuery.searchText = "händler 123"
        let search = try await clock.measure {
            _ = try await dependencies.transactionRepository.transactionPage(
                matching: searchQuery, sort: .dateDescending, offset: 0, limit: 300
            )
        }
        searchQuery.searchText = "händler 77"
        let warmSearch = try await clock.measure {
            _ = try await dependencies.transactionRepository.transactionPage(
                matching: searchQuery, sort: .dateDescending, offset: 0, limit: 300
            )
        }

        // Import: 20.000 CSV-Zeilen in ein neues Konto.
        let importAccount = Account(name: "Import", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([importAccount])
        var csv = "Datum;Beschreibung;Betrag\n"
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        formatter.locale = Locale(identifier: "de_DE")
        for index in 0..<20_000 {
            let day = calendar.date(byAdding: .hour, value: -index * 2, to: now)!
            csv += "\(formatter.string(from: day));Laden \(index % 500) Nr \(index);-\(index % 90 + 1),\(String(format: "%02d", index % 100))\n"
        }
        let pipeline = ImportPipeline(
            providers: [GenericCSVProvider(fallbackCurrency: .eur)],
            transactionRepository: dependencies.transactionRepository,
            accountRepository: dependencies.accountRepository,
            fallbackCurrency: .eur
        )
        var imported = 0
        var prepared: PreparedImport?
        let prepareDuration = try await clock.measure {
            prepared = try await pipeline.prepare(ImportFile(fileName: "gross.csv", data: Data(csv.utf8)), into: importAccount.id)
        }
        let commitDuration = try await clock.measure {
            imported = try await pipeline.commit(try #require(prepared)).importedCount
        }
        let importDuration = prepareDuration + commitDuration
        print("PERF import 20k: prepare \(prepareDuration), commit \(commitDuration)")

        print("PERF budget 100k: overview visible \(firstVisible), complete \(firstLoad), month switch \(monthSwitch) (unprepared \(unpreparedMonthSwitch)), first page \(firstPage), search \(search) (warm \(warmSearch)), import 20k \(importDuration)")

        #expect(model.snapshot != nil)
        #expect(imported == 20_000)
        // Gemessen am 17.11.2026 (Debug): Übersicht sichtbar 0,19 s, komplett
        // 2,6 s (vorher 4,2 s), Monatswechsel 2 ms vorbereitet, 0,26 s ohne
        // Vorbereitung, erste Seite 0,02 s, Suche 0,07 s (vorher 2,6 s),
        // Import von 20.000 Zeilen 14 s (vorher 80 s; optimiert 8–9 s).
        // Grenzen mit Reserve.
        #expect(firstVisible < .seconds(1))
        #expect(firstLoad < .seconds(7))
        #expect(monthSwitch < .milliseconds(100))
        #expect(unpreparedMonthSwitch < .milliseconds(500))
        #expect(firstPage < .milliseconds(300))
        #expect(search < .milliseconds(300))
        #expect(warmSearch < .milliseconds(300))
        #expect(importDuration < .seconds(25))
    }
}
