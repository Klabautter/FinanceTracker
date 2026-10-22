import Foundation

struct LoadDashboardRequest: Sendable {
    let currentMonthInterval: DateInterval
    let previousMonthInterval: DateInterval?
    let historyInterval: DateInterval
    let recentLimit: Int

    init(
        currentMonthInterval: DateInterval,
        previousMonthInterval: DateInterval?,
        historyInterval: DateInterval,
        recentLimit: Int = 8
    ) {
        self.currentMonthInterval = currentMonthInterval
        self.previousMonthInterval = previousMonthInterval
        self.historyInterval = historyInterval
        self.recentLimit = recentLimit
    }
}

struct LoadDashboardResult: Sendable {
    let current: AnalyticsSnapshot
    let previous: AnalyticsSnapshot?
    let monthlyPoints: [MonthlyCashflowPoint]
    let recentTransactions: [Transaction]
    let historyTransactions: [Transaction]
    let categories: [Category]
    /// FX-Snapshot, mit dem die Aggregate umgerechnet wurden (`nil` = keine
    /// Fremdwährung im Scope, kein Fetch nötig). Quelle (live/cache/fallback)
    /// + Stand bleiben für UI-Debug sichtbar; ein Fallback blockiert nie.
    let fxSnapshot: FXRateSnapshot?
}

struct LoadDashboard: Sendable {
    private let transactionRepository: any TransactionRepository
    private let transactionAnnotationRepository: any TransactionAnnotationRepository
    private let transactionSplitRepository: any TransactionSplitRepository
    private let categoryRepository: any CategoryRepository
    private let effectiveTransactionResolver = EffectiveTransactionResolver()

    init(
        transactionRepository: any TransactionRepository,
        transactionAnnotationRepository: any TransactionAnnotationRepository,
        transactionSplitRepository: any TransactionSplitRepository,
        categoryRepository: any CategoryRepository
    ) {
        self.transactionRepository = transactionRepository
        self.transactionAnnotationRepository = transactionAnnotationRepository
        self.transactionSplitRepository = transactionSplitRepository
        self.categoryRepository = categoryRepository
    }

    /// Bestehender Pfad mit injiziertem Calculator (reine Domain-Tests mit
    /// deterministischen Kursen). `fxSnapshot` ist dann `nil`.
    func execute(
        _ request: LoadDashboardRequest,
        calculator: AnalyticsCalculator,
        calendar: Calendar = .current
    ) async throws -> LoadDashboardResult {
        let data = try await loadData(request)
        return compute(
            request: request,
            data: data,
            calculator: calculator,
            calendar: calendar,
            fxSnapshot: nil
        )
    }

    /// Produkt-Pfad: Der Converter stammt aus dem FX-Snapshot (live →
    /// 24h-Cache → statischer Fallback, #19/#35). Gefetcht wird nur bei
    /// Fremdwährung im Scope: reine EUR-Scopes brauchen kein I/O und
    /// bleiben deterministisch (kein Netzwerk, kein Cache-Zugriff).
    func execute(
        _ request: LoadDashboardRequest,
        baseCurrency: CurrencyCode,
        fxRateProvider: any FXRateProvider,
        calendar: Calendar = .current
    ) async throws -> LoadDashboardResult {
        let data = try await loadData(request)
        let needsFX = data.historyTransactions.contains { $0.amount.currency != baseCurrency }
        let fxSnapshot: FXRateSnapshot?
        let calculator: AnalyticsCalculator
        if needsFX {
            let snapshot = await fxRateProvider.snapshot()
            fxSnapshot = snapshot
            calculator = AnalyticsCalculator(
                baseCurrency: baseCurrency,
                converter: CurrencyConverter(eurPerUnit: snapshot.eurPerUnit)
            )
        } else {
            fxSnapshot = nil
            calculator = AnalyticsCalculator(baseCurrency: baseCurrency)
        }
        return compute(
            request: request,
            data: data,
            calculator: calculator,
            calendar: calendar,
            fxSnapshot: fxSnapshot
        )
    }

    /// Geladene + effektive (annotierte) Rohdaten: noch ohne Aggregation.
    private struct LoadedData: Sendable {
        let historyTransactions: [Transaction]
        let recentTransactions: [Transaction]
        let categories: [Category]
        let splitLines: [TransactionSplitLine]
    }

    private func loadData(_ request: LoadDashboardRequest) async throws -> LoadedData {
        let intervalStart = min(
            min(
                request.historyInterval.start,
                request.previousMonthInterval?.start ?? request.currentMonthInterval.start
            ),
            request.currentMonthInterval.start
        )
        let intervalEnd = max(
            max(
                request.historyInterval.end,
                request.previousMonthInterval?.end ?? request.currentMonthInterval.end
            ),
            request.currentMonthInterval.end
        )
        async let historyTransactions = transactionRepository.transactions(
            matching: Self.query(dateInterval: DateInterval(start: intervalStart, end: intervalEnd))
        )
        async let recentTransactions = transactionRepository.recentTransactions(limit: request.recentLimit)
        async let categories = categoryRepository.categories()

        let resolvedCategories = try await categories
        let rawHistoryTransactions = try await historyTransactions
        let rawRecentTransactions = try await recentTransactions
        let unique = Dictionary(
            (rawHistoryTransactions + rawRecentTransactions).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let annotations = try await transactionAnnotationRepository.annotations(
            transactionIDs: Set(unique.keys)
        )
        let historyIDs = Set(rawHistoryTransactions.map(\.id))
        let splitLines = try await transactionSplitRepository.splitLines(parentTransactionIDs: historyIDs)
        let effectiveByID = Dictionary(
            uniqueKeysWithValues: effectiveTransactionResolver
                .applying(annotations: annotations, to: Array(unique.values))
                .map { ($0.id, $0) }
        )
        return LoadedData(
            historyTransactions: rawHistoryTransactions.compactMap { effectiveByID[$0.id] },
            recentTransactions: rawRecentTransactions.compactMap { effectiveByID[$0.id] },
            categories: resolvedCategories,
            splitLines: splitLines
        )
    }

    private func compute(
        request: LoadDashboardRequest,
        data: LoadedData,
        calculator: AnalyticsCalculator,
        calendar: Calendar,
        fxSnapshot: FXRateSnapshot?
    ) -> LoadDashboardResult {
        let resolvedCurrentTransactions = data.historyTransactions.filter {
            request.currentMonthInterval.containsHalfOpen($0.displayDate)
        }
        let scopedHistoryTransactions = data.historyTransactions.filter {
            request.historyInterval.containsHalfOpen($0.displayDate)
        }

        let currentSnapshot = calculator.snapshot(
            transactions: resolvedCurrentTransactions,
            categories: data.categories,
            calendar: calendar,
            splitLines: data.splitLines
        )

        var previousSnapshot: AnalyticsSnapshot?
        if let previousInterval = request.previousMonthInterval {
            previousSnapshot = calculator.snapshot(
                transactions: data.historyTransactions.filter {
                previousInterval.containsHalfOpen($0.displayDate)
                },
                categories: data.categories,
                calendar: calendar,
                splitLines: data.splitLines
            )
        }

        let monthlyPoints = calculator.monthlyPoints(
            transactions: scopedHistoryTransactions,
            monthsBack: 6,
            calendar: calendar,
            splitLines: data.splitLines,
            // Der Verlauf endet am angezeigten Monat, nicht an „heute".
            referenceDate: request.currentMonthInterval.start
        )

        return LoadDashboardResult(
            current: currentSnapshot,
            previous: previousSnapshot,
            monthlyPoints: monthlyPoints,
            recentTransactions: data.recentTransactions,
            historyTransactions: scopedHistoryTransactions,
            categories: data.categories,
            fxSnapshot: fxSnapshot
        )
    }

    private static func query(
        dateInterval: DateInterval? = nil,
        sort: TransactionSortOrder = .dateDescending,
        limit: Int? = nil
    ) -> TransactionQuery {
        var query = TransactionQuery()
        query.dateInterval = dateInterval
        query.sort = sort
        query.limit = limit
        return query
    }
}
