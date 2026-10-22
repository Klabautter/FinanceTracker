import Foundation
import os
import SwiftData
import XCTest

@testable import FinanceTracker

/// WP33 (§230–237): Deterministisches 50k-Fixture auf einem disk-backed
/// Temp-Store + XCTest-Metrics. Die Tests laufen NUR im Performance-Scheme
/// (PERF_50K=1), der normale Test-Gate skippt sie schnell, damit die
/// Messungen den CI-Alltag nicht verfälschen.
final class Performance50kTests: XCTestCase {

    private nonisolated(unsafe) static var dependencies: AppDependencies?
    private nonisolated(unsafe) static var fixtureDirectory: URL?
    private nonisolated(unsafe) static var firstTagID: UUID?
    private static let rowCount = 50_000

    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["PERF_50K"] == "1" else { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-50k-\(UUID().uuidString)", isDirectory: true)
        guard let container = try? SwiftDataStore(url: directory.appendingPathComponent("perf.store")).container else {
            XCTFail("50k Fixture-Store konnte nicht erstellt werden")
            return
        }
        fixtureDirectory = directory
        seedSync(container: container)
    }

    /// Synchroner, deterministischer Seed direkt über Entity-Inserts
    /// kein MainActor-Hopping (Deadlock-Gefahr in class setUp).
    private static func seedSync(container: ModelContainer) {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let calendar = Calendar(identifier: .gregorian)
        // WP38-Korrektur: Rows über die letzten 730 Tage bis JETZT verteilen
        // sonst messen Analytics/Budgets (aktueller Monat) leere Ergebnismengen.
        let now = Date()
        let spanSeconds: TimeInterval = 730 * 24 * 3600
        let baseDate = calendar.date(byAdding: .day, value: -730, to: calendar.startOfDay(for: now))!
        let folding: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        }

        // Konten (5)
        var accountIDs: [UUID] = []
        for index in 0..<5 {
            let id = UUID()
            accountIDs.append(id)
            context.insert(SDAccountEntity(
                id: id, connectionID: nil, institutionID: nil,
                name: "Konto \(index)", typeRaw: "checking", currencyRaw: "EUR",
                maskedIdentifier: nil, ibanLast4: nil,
                providerAccountID: "perf-\(index)", sourceRaw: "demo", isActive: true
            ))
        }

        // Kategorien (20) + Tags (50)
        var categoryIDs: [UUID] = []
        for index in 0..<20 {
            let id = UUID()
            categoryIDs.append(id)
            context.insert(SDCategoryEntity(
                id: id, name: "Kategorie \(index)",
                systemIconName: "tag", colorTokenRaw: "blue", parentID: nil
            ))
        }
        var tagIDs: [UUID] = []
        for index in 0..<50 {
            let id = UUID()
            tagIDs.append(id)
            context.insert(SDTagEntity(id: id, name: "Tag \(index)", colorTokenRaw: "teal"))
        }

        // Transaktionen (50.000) in Chunks + Join-Rows + Annotationen (2.000)
        let chunkSize = 5_000
        let tagRowsLock = NSLock()
        var pendingTagRows: [SDTransactionTagEntity] = []

        for chunkStart in stride(from: 0, to: 50_000, by: chunkSize) {
            for index in chunkStart..<min(chunkStart + chunkSize, 50_000) {
                let txnID = UUID()
                let accountID = accountIDs[index % accountIDs.count]
                let categoryID = categoryIDs[index % categoryIDs.count]
                let merchant = "Händler \(index % 100)"
                let bookedAt = baseDate.addingTimeInterval(TimeInterval(index) * spanSeconds / 50_000)
                let carriesTag = index % 3 == 0
                let txnTagIDs = carriesTag ? [tagIDs[index % tagIDs.count]] : []
                let note = index < 2_000 ? "Notiz \(index)" : nil

                context.insert(SDTransactionEntity(
                    id: txnID,
                    accountID: accountID,
                    sourceRaw: "demo",
                    externalID: "perf-\(index)",
                    sourceFingerprint: nil,
                    statusRaw: "booked",
                    kindRaw: "purchase",
                    amountValue: "\(index % 500 + 1)",
                    amountCurrencyRaw: "EUR",
                    bookedAt: bookedAt,
                    authorizedAt: nil,
                    valueDate: nil,
                    effectiveDateValue: bookedAt,
                    rawDescription: merchant,
                    rawMerchantName: merchant,
                    merchantID: nil,
                    merchantDisplayName: merchant,
                    categoryID: categoryID,
                    paymentMethodRaw: nil,
                    originalCurrencyRaw: nil,
                    originalAmountValue: nil,
                    cryptoAsset: nil,
                    cryptoAmountValue: nil,
                    cashbackAmountValue: nil,
                    cashbackCurrencyRaw: nil,
                    importBatchID: nil,
                    searchableText: "\(folding(merchant)) perf-\(index)",
                    note: note,
                    reviewed: index % 2 == 0,
                    excludedFromAnalytics: false,
                    tagIDsJSON: txnTagIDs.isEmpty ? nil : try? JSONEncoder().encode(txnTagIDs),
                    createdAt: bookedAt,
                    updatedAt: bookedAt
                ))

                for tagID in txnTagIDs {
                    tagRowsLock.lock()
                    pendingTagRows.append(SDTransactionTagEntity(transactionID: txnID, tagID: tagID))
                    tagRowsLock.unlock()
                }

                if index < 2_000 {
                    context.insert(SDTransactionAnnotationEntity(
                        id: UUID(),
                        transactionID: txnID,
                        note: note,
                        reviewed: false,
                        excludedFromAnalytics: false,
                        manualKindOverrideRaw: nil,
                        tagIDsJSON: nil,
                        createdAt: bookedAt,
                        updatedAt: bookedAt
                    ))
                }

                if index < 500 {
                    context.insert(SDTransactionSplitLineEntity(
                        id: UUID(),
                        parentTransactionID: txnID,
                        amountValue: "5",
                        categoryID: nil,
                        note: nil,
                        createdAt: bookedAt
                    ))
                }

                if index < 300 {
                    context.insert(SDTransactionAttachmentEntity(
                        id: UUID(),
                        transactionID: txnID,
                        fileName: "beleg.pdf",
                        mimeType: "application/pdf",
                        localRelativePath: "\(txnID.uuidString)/perf.pdf",
                        createdAt: bookedAt
                    ))
                }
            }
            try? context.save()
        }

        // Tag-Join-Rows (WP19-Index)
        pendingTagRows.forEach { context.insert($0) }
        try? context.save()

        // Recurring Commitments (30) + Budgets (20)
        for index in 0..<30 {
            context.insert(SDRecurringCommitmentEntity(
                id: UUID(),
                name: "Abo \(index)",
                merchantKey: "ABO \(index)",
                directionRaw: index % 4 == 0 ? "income" : "expense",
                cadenceRaw: "monthly",
                amountPolicyRaw: "fixed",
                expectedAmountValue: "\(index + 5)",
                currencyRaw: "EUR",
                categoryID: nil,
                nextExpectedDate: Date(),
                statusRaw: "active",
                originRaw: "manual",
                createdAt: Date(),
                updatedAt: Date()
            ))
        }
        for index in 0..<20 {
            context.insert(SDBudget2Entity(
                id: UUID(),
                name: "Budget \(index)",
                systemIconName: "chart.pie",
                amountValue: "\(500 + index)",
                currencyRaw: "EUR",
                periodPolicyRaw: "calendarMonth",
                startDay: 1,
                salaryIncomeID: nil,
                categoryIDsJSON: Data("[]".utf8),
                tagIDsJSON: nil,
                accountIDsJSON: nil,
                rolloverRaw: "reset",
                includeInForecast: true,
                enabled: true,
                createdAt: Date(),
                updatedAt: Date()
            ))
        }
        try? context.save()
    }

    override class func tearDown() {
        super.tearDown()
        if let directory = fixtureDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        fixtureDirectory = nil
        dependencies = nil
        firstTagID = nil
    }

    /// §231: Deterministisches Dataset: 50.000 Transaktionen, 5 Konten,
    /// 20 Kategorien, 50 Tags, 100 Merchant-Namen, 30 Commitments,
    /// 20 Budgets, 2.000 Annotationen, 500 Split-Rows, 300 Attachment-
    /// Metadaten.
    private func makeDependencies() throws -> AppDependencies {
        try requirePerfMode()
        guard let directory = Self.fixtureDirectory,
              let container = try? SwiftDataStore(url: directory.appendingPathComponent("perf.store")).container else {
            XCTFail("Fixture-Container fehlt")
            throw XCTSkip("Fixture fehlt")
        }
        return AppDependencies.make(container: container, baseCurrency: .eur)
    }

    private func requirePerfMode() throws {
        guard ProcessInfo.processInfo.environment["PERF_50K"] == "1" else {
            throw XCTSkip("Performance-Suite nur im Performance-Scheme (PERF_50K=1)")
        }
    }

    private func measureAsync(
        _ label: String,
        timeout: TimeInterval = 120,
        signpostNames: [String] = [],
        _ body: @escaping @MainActor () async throws -> Void
    ) {
        let clock = XCTClockMetric()
        let memory = XCTMemoryMetric()
        // Nur die vom jeweiligen Flow tatsächlich emittierten Intervalle
        // registrieren. Sieben unbeteiligte XCTOSSignpostMetrics pro Test
        // machten den Metrikdienst unnötig schwer und konnten beim Stoppen
        // einer Iteration hängen bleiben.
        let signposts = signpostNames.map {
            XCTOSSignpostMetric(
                subsystem: "de.klabautter.FinanceTracker",
                category: "performance",
                name: $0
            )
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [clock, memory] + signposts, options: options) {
            let exp = expectation(description: label)
            Task { @MainActor in
                do {
                    try await body()
                } catch {
                    XCTFail("\(label): \(error)")
                }
                exp.fulfill()
            }
            wait(for: [exp], timeout: timeout)
        }
    }

    // MARK: - Messungen (§234)

    func testTransactionsFirstPage() throws {
        let dependencies = try makeDependencies()
        measureAsync("Transactions first page", signpostNames: ["TransactionSearch"]) {
            let model = TransactionsModel(dependencies: dependencies)
            await model.refresh()
        }
    }

    func testDashboardFirstLoad50k() throws {
        let dependencies = try makeDependencies()
        measureAsync(
            "Dashboard first load 50k",
            timeout: 180,
            signpostNames: ["DashboardLoad", "ForecastCompute"]
        ) {
            let model = DashboardModel(dependencies: dependencies)
            await model.load()
        }
    }

    func testSearch50k() throws {
        let dependencies = try makeDependencies()
        measureAsync("Search 50k", signpostNames: ["TransactionSearch"]) {
            var query = TransactionQuery()
            query.searchText = "händler 123"
            _ = try await dependencies.transactionRepository.transactionPage(
                matching: query, sort: .dateDescending, offset: 0, limit: 300
            )
        }
    }

    func testTagFilter50k() async throws {
        let dependencies = try makeDependencies()
        let tags = try await dependencies.tagRepository.tags()
        guard let tagID = tags.first?.id else {
            XCTFail("Keine Tags im Fixture")
            return
        }
        measureAsync("Tag filter 50k", signpostNames: ["TransactionSearch"]) {
            var query = TransactionQuery()
            query.tagIDs = Set([tagID])
            _ = try await dependencies.transactionRepository.transactionPage(
                matching: query, sort: .dateDescending, offset: 0, limit: 300
            )
        }
    }

    func testAnalyticsTwelveMonths() throws {
        let dependencies = try makeDependencies()
        measureAsync("Analytics 12M", timeout: 180, signpostNames: ["AnalyticsLoad"]) {
            let model = AnalyticsModel(dependencies: dependencies)
            await model.load()
        }
    }

    func testBudgetOverview50k() throws {
        let dependencies = try makeDependencies()
        measureAsync("Budget overview 50k", signpostNames: ["BudgetLoad"]) {
            let model = BudgetsModel(dependencies: dependencies)
            await model.load()
        }
    }

    func testCSVExport50k() throws {
        let dependencies = try makeDependencies()
        measureAsync("CSV export 50k", timeout: 180, signpostNames: ["CSVExport"]) {
            _ = try await CSVExportService.makeDocument(dependencies: dependencies)
        }
    }

    func testBackupExport50k() throws {
        let dependencies = try makeDependencies()
        measureAsync("Backup export 50k", timeout: 180, signpostNames: ["BackupExport"]) {
            _ = try await BackupService.makeBackup(dependencies: dependencies)
        }
    }
}
