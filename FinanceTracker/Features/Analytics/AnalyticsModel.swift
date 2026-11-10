import Foundation

struct AnalyticsScope: Hashable, Sendable {
    let rangeTitle: String
    let query: TransactionQuery
    let accountNames: [String]
    let categoryNames: [String]
    let source: TransactionSource?

    var summary: String {
        [
            rangeTitle,
            selectionSummary(
                accountNames,
                allTitle: String(localized: "Alle Konten"),
                countTitle: { String(localized: "\($0) Konten") }
            ),
            selectionSummary(
                categoryNames,
                allTitle: String(localized: "Alle Kategorien"),
                countTitle: { String(localized: "\($0) Kategorien") }
            ),
            source?.displayName ?? String(localized: "Alle Quellen")
        ].joined(separator: " · ")
    }

    func inMonth(_ interval: DateInterval) -> AnalyticsScope {
        var monthQuery = query
        monthQuery.dateInterval = interval
        return AnalyticsScope(rangeTitle: AppDateFormatter.monthYear(interval.start), query: monthQuery,
                              accountNames: accountNames, categoryNames: categoryNames, source: source)
    }

    func query(searchText: String) -> TransactionQuery {
        var scopedQuery = query
        scopedQuery.searchText = searchText
        return scopedQuery
    }

    private func selectionSummary(
        _ names: [String],
        allTitle: String,
        countTitle: (Int) -> String
    ) -> String {
        guard !names.isEmpty else { return allTitle }
        if names.count <= 2 {
            return names.joined(separator: ", ")
        }
        return countTitle(names.count)
    }
}

@MainActor
@Observable
final class AnalyticsModel {
    enum DateRange: String, CaseIterable, Identifiable {
        case last3Months = "Letzte 3 Monate"
        case last6Months = "Letzte 6 Monate"
        case last12Months = "Letzte 12 Monate"
        case thisYear = "Dieses Jahr"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .last3Months: String(localized: "Letzte 3 Monate")
            case .last6Months: String(localized: "Letzte 6 Monate")
            case .last12Months: String(localized: "Letzte 12 Monate")
            case .thisYear: String(localized: "Dieses Jahr")
            }
        }

        var monthsBack: Int {
            switch self {
            case .last3Months: 3
            case .last6Months: 6
            case .last12Months: 12
            case .thisYear: Calendar.current.component(.month, from: Date())
            }
        }

        func interval(calendar: Calendar) -> DateInterval? {
            let now = Date()
            switch self {
            case .last3Months, .last6Months, .last12Months:
                guard let currentStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
                      let start = calendar.date(byAdding: .month, value: -(monthsBack - 1), to: currentStart),
                      let end = calendar.date(byAdding: .month, value: 1, to: currentStart) else { return nil }
                return DateInterval(start: start, end: end)
            case .thisYear:
                guard let start = calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: 1, day: 1)),
                      let end = calendar.date(byAdding: .year, value: 1, to: start) else { return nil }
                return DateInterval(start: start, end: end)
            }
        }
    }

    let dependencies: AppDependencies
    private let calendar: Calendar
    private let effectiveTransactionResolver = EffectiveTransactionResolver()

    private(set) var snapshot: AnalyticsSnapshot?
    private(set) var previousSnapshot: AnalyticsSnapshot?
    /// Jedes Konto mit Ausgaben in der aktuellen Periode hat auch Daten aus
    /// der ersten Hälfte der Vorperiode. Sonst wäre der Vergleich schief.
    private(set) var previousPeriodCovered = false
    private(set) var monthlyPoints: [MonthlyCashflowPoint] = []
    private(set) var scope: AnalyticsScope?
    private(set) var availableAccounts: [Account] = []
    private(set) var availableCategories: [Category] = []
    /// Laden der Analyse (AGENTS #37); diese Ansicht hat keine Aktionen.
    private(set) var loadState: LoadState = .idle
    var isLoading: Bool { loadState.isLoading }
    /// FX-Status für UI-Debug (Quelle live/cache/fallback + Stand). `nil` =
    /// keine Fremdwährung im Scope (kein Fetch nötig) oder noch nie geladen.
    /// Ein Fallback blockiert die Analyse nie, er gilt immer.
    private(set) var fxSnapshot: FXRateSnapshot?
    private(set) var fxIsLoading = false

    /// Snapshot-Cache (Roadmap #180): Ergebnis-Paket pro Filter-Konstellation
    /// und Datenrevision. Macht Hin-und-Her-Filterwechsel sofortig.
    private struct CacheKey: Hashable {
        let revision: Int
        let range: DateRange
        let accounts: Set<UUID>
        let categories: Set<UUID>
        let source: TransactionSource?
        let baseCurrency: CurrencyCode
    }

    /// WP16: Cache-Entry ohne vollständige Transaction-History:
    /// Aggregate reichen; Drilldowns queryn on demand. Der FX-Snapshot
    /// gehört dazu: Bei geänderten Kursen ist der Eintrag veraltet und wird
    /// neu berechnet (stille Mischkurse wären #19/#35).
    private struct CacheEntry {
        let snapshot: AnalyticsSnapshot
        let previousSnapshot: AnalyticsSnapshot
        let previousPeriodCovered: Bool
        let monthlyPoints: [MonthlyCashflowPoint]
        let scope: AnalyticsScope
        let fxSnapshot: FXRateSnapshot?
    }

    /// WP16: Bounded LRU (§115): max. 6 Einträge, ältester wird verdrängt.
    private struct LRUCache {
        private var order: [CacheKey] = []
        private var entries: [CacheKey: CacheEntry] = [:]
        let capacity: Int

        init(capacity: Int = 6) {
            self.capacity = max(1, capacity)
        }

        func entry(for key: CacheKey) -> CacheEntry? {
            entries[key]
        }

        mutating func touch(_ key: CacheKey) {
            order.removeAll { $0 == key }
            order.insert(key, at: 0)
        }

        mutating func insert(_ entry: CacheEntry, for key: CacheKey) {
            entries[key] = entry
            order.removeAll { $0 == key }
            order.insert(key, at: 0)
            while order.count > capacity {
                let oldest = order.removeLast()
                entries[oldest] = nil
            }
        }

        mutating func removeAll() {
            order = []
            entries = [:]
        }

        var count: Int { entries.count }
    }

    private var cache = LRUCache()
    private var cacheRevision: Int = -1
    private var activeFilterLoadTask: Task<Void, Never>?

    var range: DateRange = .last12Months
    var filterAccountIDs: Set<UUID> = []
    var filterCategoryIDs: Set<UUID> = []
    var filterSource: TransactionSource?

    static let historyMonths = 12

    init(dependencies: AppDependencies, calendar: Calendar = .current) {
        self.dependencies = dependencies
        self.calendar = calendar
    }

    var currency: CurrencyCode { dependencies.baseCurrency }
    var dataRevision: Int { dependencies.changeTracker.revision }

    var activeFilterCount: Int {
        filterAccountIDs.count + filterCategoryIDs.count + (filterSource != nil ? 1 : 0)
    }

    /// Führende Monate ohne Daten werden nicht als große leere Achse gezeigt.
    /// Lücken innerhalb des tatsächlichen Datenbereichs bleiben sichtbar.
    var displayedMonthlyPoints: [MonthlyCashflowPoint] {
        guard let firstDataIndex = monthlyPoints.firstIndex(where: { point in
            point.income != 0 || point.spending != 0
        }) else { return [] }
        return Array(monthlyPoints[firstDataIndex...])
    }

    /// WP15: Load-Generation: verhindert, dass ein veralteter Load ein
    /// neueres Ergebnis überschreibt (Rapid-Filterwechsel). Der Zähler wird
    /// bei JEDEM load()-Start erhöht; nur der zuletzt gestartete Load darf
    /// committen.
    private var loadGeneration = 0

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        loadState = .loading
        let signpost = PerfSignpost.signposter.beginInterval("AnalyticsLoad")
        defer {
            PerfSignpost.signposter.endInterval("AnalyticsLoad", signpost)
            // Ein abgebrochener Load (Filterwechsel, View verschwindet) darf
            // keinen Spinner hinterlassen; ein neuerer Load verwaltet ihn selbst.
            if generation == loadGeneration, loadState == .loading { loadState = .loaded }
        }

        let key = CacheKey(
            revision: dataRevision,
            range: range,
            accounts: filterAccountIDs,
            categories: filterCategoryIDs,
            source: filterSource,
            baseCurrency: dependencies.baseCurrency
        )

        if key.revision != cacheRevision {
            cache.removeAll()
            cacheRevision = key.revision
        }
        if let entry = cache.entry(for: key) {
            // Cache-Hit: sofort committen (generation-guarded). Ein veralteter
            // Load berührt isLoading nicht, wenn längst ein neuerer läuft.
            guard generation == loadGeneration else { return }
            // Fremdwährungs-Einträge gegen aktuelle Kurse revalidieren:
            // geänderte Kurse machen den Eintrag still veraltet (#19/#35).
            // Reine EUR-Einträge brauchen kein FX-I/O.
            var useCache = true
            if let entryFX = entry.fxSnapshot {
                fxIsLoading = true
                let currentFX = await dependencies.fxRateProvider.snapshot()
                fxIsLoading = false
                guard generation == loadGeneration, !Task.isCancelled else { return }
                fxSnapshot = currentFX
                useCache = (currentFX == entryFX)
            } else {
                fxSnapshot = nil
            }
            if useCache {
                cache.touch(key)
                snapshot = entry.snapshot
                previousSnapshot = entry.previousSnapshot
                previousPeriodCovered = entry.previousPeriodCovered
                monthlyPoints = entry.monthlyPoints
                scope = entry.scope
                loadState = .loaded
                return
            }
            // Kurse geändert → fällt in die Neuberechnung unten.
        }

        do {
            let currentInterval = range.interval(calendar: calendar) ?? DateInterval(start: .distantPast, duration: 0)
            let prevInterval = previousInterval(current: currentInterval)
            async let categoriesTask = dependencies.categoryRepository.categories()
            async let accountsTask = dependencies.accountRepository.accounts()

            let categories = try await categoriesTask
            let accounts = try await accountsTask
            let currentScope = makeScope(interval: currentInterval, categories: categories, accounts: accounts)
            var previousQuery = currentScope.query
            previousQuery.dateInterval = prevInterval
            async let transactionsTask = fetchTransactions(query: currentScope.query)
            async let previousTransactionsTask = fetchTransactions(query: previousQuery)

            let transactions = try await transactionsTask
            let previousTransactions = try await previousTransactionsTask

            // WP17: Split-Lines nur für die Txns im Analytics-Scope.
            let splitLines = try await dependencies.transactionSplitRepository.splitLines(
                parentTransactionIDs: Set(transactions.map(\.id) + previousTransactions.map(\.id))
            )

            // WP15: Ein veralteter Load (zwischenzeitlich neuer Filterwechsel)
            // darf nichts committen, auch keinen Error-State.
            guard generation == loadGeneration, !Task.isCancelled else { return }

            availableAccounts = accounts
            availableCategories = categories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // FX nur bei Fremdwährung im Scope (#19/#35); reine
            // EUR-Scopes brauchen kein I/O und bleiben deterministisch.
            // Der Provider liefert immer einen Snapshot (live → 24h-Cache →
            // statischer Fallback); ein Fetch-Fehler blockiert nie.
            let needsFX = transactions.contains { $0.amount.currency != dependencies.baseCurrency }
                || previousTransactions.contains { $0.amount.currency != dependencies.baseCurrency }
            let resolvedFX: FXRateSnapshot?
            if needsFX {
                fxIsLoading = true
                let fetched = await dependencies.fxRateProvider.snapshot()
                fxIsLoading = false
                guard generation == loadGeneration, !Task.isCancelled else { return }
                resolvedFX = fetched
            } else {
                resolvedFX = nil
            }
            fxSnapshot = resolvedFX
            let calculator = AnalyticsCalculator(
                baseCurrency: dependencies.baseCurrency,
                converter: resolvedFX.map { $0.converter } ?? CurrencyConverter()
            )
            let calculationCalendar = calendar
            let monthsBack = range.monthsBack
            let calculations = await Task.detached(priority: .userInitiated) {
                let snapshot = calculator.snapshot(
                    transactions: transactions,
                    categories: categories,
                    calendar: calculationCalendar,
                    splitLines: splitLines,
                    categoryIDs: currentScope.query.categoryIDs
                )
                let previous = calculator.snapshot(
                    transactions: previousTransactions,
                    categories: categories,
                    calendar: calculationCalendar,
                    splitLines: splitLines,
                    categoryIDs: currentScope.query.categoryIDs
                )
                let monthly = calculator.monthlyPoints(
                    transactions: transactions,
                    monthsBack: monthsBack,
                    calendar: calculationCalendar,
                    splitLines: splitLines,
                    categoryIDs: currentScope.query.categoryIDs
                )
                return (snapshot, previous, monthly)
            }.value

            // Auch während der CPU-Phase kann ein neuer Filterload starten.
            // Nur der aktuelle Lauf darf seine fertigen Aggregate committen.
            guard generation == loadGeneration, !Task.isCancelled else { return }
            let calculatedSnapshot = calculations.0
            let calculatedPrevious = calculations.1
            let calculatedMonthly = calculations.2

            let covered = Self.previousPeriodCovered(
                current: transactions,
                previous: previousTransactions,
                previousInterval: prevInterval
            )
            snapshot = calculatedSnapshot
            previousSnapshot = calculatedPrevious
            previousPeriodCovered = covered
            monthlyPoints = calculatedMonthly
            scope = currentScope

            cache.insert(
                CacheEntry(
                    snapshot: calculatedSnapshot,
                    previousSnapshot: calculatedPrevious,
                    previousPeriodCovered: covered,
                    monthlyPoints: calculatedMonthly,
                    scope: currentScope,
                    fxSnapshot: resolvedFX
                ),
                for: key
            )

            if generation == loadGeneration {
                loadState = .loaded
            }
        } catch {
            // WP15: Auch der Error eines veralteten Loads überschreibt den
            // Zustand des aktuellen Loads nicht.
            guard generation == loadGeneration, !Task.isCancelled else { return }
            loadState = .failed(String(localized: "Die Analyse konnte nicht geladen werden."))
        }
    }

    func filtersChanged() {
        // Zwischen Filterauswahl und Task-Start dürfen die alten Aggregate
        // nicht unter dem neuen Filterzustand stehen bleiben.
        loadGeneration += 1
        snapshot = nil
        previousSnapshot = nil
        previousPeriodCovered = false
        monthlyPoints = []
        scope = nil
        loadState = .loading
        activeFilterLoadTask?.cancel()
        activeFilterLoadTask = Task { [weak self] in
            await self?.load()
        }
    }

    func resetFilters() {
        range = .last12Months
        filterAccountIDs = []
        filterCategoryIDs = []
        filterSource = nil
        filtersChanged()
    }

    /// Roadmap #92: Ausgaben-Vergleich zum gleichen Abschnitt der
    /// vorangehenden Periode (siehe `previousInterval(current:now:calendar:)`).
    var spendingTrendPercent: Double? {
        guard let current = snapshot?.totalSpending,
              let previous = previousSnapshot?.totalSpending,
              previous > 0,
              previousPeriodCovered else { return nil }
        return NSDecimalNumber(decimal: (current - previous) / previous).doubleValue
    }

    /// Nur vergleichen, wenn die Vorperiode für jedes Konto mit Ausgaben in
    /// der aktuellen Periode Daten hat, und zwar schon aus ihrer ersten
    /// Hälfte. Kam ein Konto erst später dazu (Bankanbindung, neue Karte),
    /// wäre „↑ 209 %" nur ein Effekt der fehlenden Daten.
    nonisolated static func previousPeriodCovered(
        current: [Transaction],
        previous: [Transaction],
        previousInterval: DateInterval
    ) -> Bool {
        let spendingAccounts = Set(current.filter { $0.amount.isNegative }.map(\.accountID))
        guard !spendingAccounts.isEmpty else { return false }
        let halfway = previousInterval.start.addingTimeInterval(previousInterval.duration / 2)
        var earliest: [UUID: Date] = [:]
        for transaction in previous {
            let date = transaction.displayDate
            if earliest[transaction.accountID].map({ date < $0 }) ?? true {
                earliest[transaction.accountID] = date
            }
        }
        return spendingAccounts.allSatisfy { account in
            earliest[account].map { $0 <= halfway } ?? false
        }
    }

    var spendingDeltaText: String? {
        guard let trend = spendingTrendPercent else { return nil }
        let percent = Int((abs(trend) * 100).rounded())
        let arrow = trend < 0 ? "↓" : "↑"
        return String(localized: "\(arrow) \(percent) % vs. Vorperiode")
    }

    var categoryPieItems: [CategoryTotal] {
        guard let all = snapshot?.spendingByCategory, !all.isEmpty else { return [] }
        if all.count <= 8 {
            return all
        }
        let top = Array(all.prefix(8))
        let restAmount = all.dropFirst(8).reduce(into: Decimal(0)) { partial, item in
            partial += item.amount
        }

        let restBucket = CategoryTotal(categoryID: nil, name: String(localized: "Weitere Kategorien (\(all.count - 8))"), amount: restAmount, isRemainder: true)
        return top + [restBucket]
    }

    var topMerchants: [MerchantTotal] {
        Array(snapshot?.spendingByMerchant.prefix(10) ?? [])
    }

    var parentCategoriesForFilter: [Category] {
        availableCategories.filter { $0.parentID == nil }
    }

    private func makeScope(
        interval: DateInterval,
        categories: [Category],
        accounts: [Account]
    ) -> AnalyticsScope {
        var query = TransactionQuery()
        query.dateInterval = interval
        let hierarchy = CategoryHierarchy()
        query.categoryIDs = Set(
            filterCategoryIDs.flatMap { hierarchy.descendantIDs(of: $0, in: categories) }
        )
        query.accountIDs = filterAccountIDs
        if let filterSource {
            query.sources = [filterSource]
        }

        let selectedAccountNames = accounts
            .filter { filterAccountIDs.contains($0.id) }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let selectedCategoryNames = categories
            .filter { filterCategoryIDs.contains($0.id) }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return AnalyticsScope(
            rangeTitle: range.title,
            query: query,
            accountNames: selectedAccountNames,
            categoryNames: selectedCategoryNames,
            source: filterSource
        )
    }

    private func fetchTransactions(query: TransactionQuery) async throws -> [Transaction] {
        return try await resolveAnnotations(
            for: try await dependencies.transactionRepository.transactions(matching: query)
        )
    }

    private func previousInterval(current: DateInterval) -> DateInterval {
        Self.previousInterval(current: current, now: Date(), calendar: calendar)
    }

    /// Roadmap #92: Vergleichszeitraum vor `current`.
    ///
    /// Er beginnt gleich viele Kalendermonate früher (01.09.–01.12. →
    /// 01.06.–01.09., nicht 02.06.) und reicht, solange `current` noch läuft,
    /// nur bis zum entsprechenden Tag: Am 09.11. steht „01.09. bis heute"
    /// gegen „01.06. bis 09.08.". Sonst träte ein angebrochener Zeitraum
    /// gegen einen vollen an und zeigte immer einen Rückgang.
    nonisolated static func previousInterval(
        current: DateInterval,
        now: Date,
        calendar: Calendar
    ) -> DateInterval {
        let months = calendar.dateComponents([.month], from: current.start, to: current.end).month ?? 0
        guard months > 0,
              let previousStart = calendar.date(byAdding: .month, value: -months, to: current.start) else {
            return DateInterval(
                start: current.start.addingTimeInterval(-current.duration),
                duration: current.duration
            )
        }
        guard now >= current.start, now < current.end,
              let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return DateInterval(start: previousStart, end: current.start)
        }
        let elapsed = calendar.dateComponents(
            [.month, .day],
            from: current.start,
            to: min(startOfTomorrow, current.end)
        )
        let cutoff = calendar.date(byAdding: elapsed, to: previousStart) ?? current.start
        return DateInterval(start: previousStart, end: min(max(cutoff, previousStart), current.start))
    }

    private func resolveAnnotations(for transactions: [Transaction]) async throws -> [Transaction] {
        let annotations = try await dependencies.transactionAnnotationRepository.annotations(
            transactionIDs: Set(transactions.map(\.id))
        )
        return effectiveTransactionResolver.applying(annotations: annotations, to: transactions)
    }
}
