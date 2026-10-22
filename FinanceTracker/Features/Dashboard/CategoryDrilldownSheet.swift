import SwiftUI

/// WP12 (§88-95): Kategorie-Drilldown: ID-basiert (Namen sind kein
/// stabiler Identifier), rekursive Descendants, scoped Query mit
/// Pagination statt Full-History-Load und sichtbarem Fehler-State.
struct CategoryDrilldownSheet: View {
    let categoryID: UUID?
    let categoryName: String
    let dateInterval: DateInterval
    let currency: CurrencyCode
    @Environment(\.dismiss) private var dismiss

    @State private var model: CategoryDrilldownModel

    init(
        categoryID: UUID?,
        categoryName: String,
        dateInterval: DateInterval,
        currency: CurrencyCode,
        dependencies: AppDependencies,
        scope: AnalyticsScope? = nil
    ) {
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.dateInterval = dateInterval
        self.currency = currency
        _model = State(initialValue: CategoryDrilldownModel(
            categoryID: categoryID,
            dateInterval: dateInterval,
            currency: currency,
            dependencies: dependencies,
            scope: scope
        ))
    }

    var body: some View {
        AdaptiveSheet(title: categoryName) {
            Group {
                if model.isLoading {
                    LoadingStateView()
                } else if let errorMessage = model.errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await model.load() }
                    }
                } else if model.transactions.isEmpty {
                    EmptyStateView(
                        title: String(localized: "Keine Transaktionen"),
                        message: String(localized: "Für „\(categoryName)“ wurden im ausgewählten Zeitraum keine Ausgaben gefunden."),
                        systemImage: "tray"
                    )
                } else {
                    transactionList
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 560)
        #endif
        .task { await model.load() }
    }

    private var transactionList: some View {
        Form {
            ForEach(model.transactions) { txn in
                TransactionRowView(transaction: txn, category: nil)
                    .accessibilityElement(children: .combine)
            }
            if model.canLoadMore {
                Button {
                    Task { await model.loadNextPage() }
                } label: {
                    if model.isLoadingPage {
                        ProgressView()
                    } else {
                        Text("Weitere laden")
                    }
                }
                .disabled(model.isLoadingPage)
            }
        }
        .financeFormStyle()
    }

}

@MainActor
@Observable
final class CategoryDrilldownModel {
    private let categoryID: UUID?
    private let dateInterval: DateInterval
    private let currency: CurrencyCode
    private let dependencies: AppDependencies
    private let effectiveTransactionResolver = EffectiveTransactionResolver()
    private var calculator: AnalyticsCalculator?
    private let pageSize: Int
    private let scope: AnalyticsScope?
    private var categoryIDs: Set<UUID> = []
    private var rawOffset = 0

    private(set) var transactions: [Transaction] = []
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var canLoadMore = false
    private(set) var isLoadingPage = false

    init(
        categoryID: UUID?,
        dateInterval: DateInterval,
        currency: CurrencyCode,
        dependencies: AppDependencies,
        pageSize: Int = 300,
        scope: AnalyticsScope? = nil
    ) {
        self.categoryID = categoryID
        self.dateInterval = dateInterval
        self.currency = currency
        self.dependencies = dependencies
        self.pageSize = pageSize
        self.scope = scope
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        transactions = []
        rawOffset = 0
        defer { isLoading = false }

        do {
            let categories = try await dependencies.categoryRepository.categories()
            categoryIDs = categoryID.map { CategoryHierarchy().descendantIDs(of: $0, in: categories) } ?? []
            calculator = AnalyticsCalculator(baseCurrency: currency, converter: await dependencies.fxRateProvider.converter())
            try await appendPagesUntilVisible()
        } catch {
            errorMessage = String(localized: "Transaktionen konnten nicht geladen werden.")
            transactions = []
            canLoadMore = false
        }
    }

    func loadNextPage() async {
        guard canLoadMore, !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        do {
            try await appendPagesUntilVisible()
        } catch {
            errorMessage = String(localized: "Weitere Transaktionen konnten nicht geladen werden.")
        }
    }

    private func appendPagesUntilVisible() async throws {
        let visibleCountBeforeLoad = transactions.count
        repeat {
            var query = scope?.query ?? TransactionQuery()
            // Kategorie wird nach effektiven Fakten und Splits ausgewertet.
            query.categoryIDs = []
            query.dateInterval = dateInterval

            let page = try await dependencies.transactionRepository.transactionPage(
                matching: query,
                sort: .dateDescending,
                offset: rawOffset,
                limit: pageSize
            )
            rawOffset += page.transactions.count
            canLoadMore = page.hasMore

            let annotations = try await dependencies.transactionAnnotationRepository.annotations(
                transactionIDs: Set(page.transactions.map(\.id))
            )
            let effective = effectiveTransactionResolver.applying(
                annotations: annotations,
                to: page.transactions
            )
            let splits = try await dependencies.transactionSplitRepository.splitLines(
                parentTransactionIDs: Set(effective.map(\.id))
            )
            let selectedCategories: Set<UUID?> = categoryID == nil ? [nil] : Set(categoryIDs.map { Optional($0) })
            let visibleIDs = calculator?.transactionIDsContributing(
                to: selectedCategories, transactions: effective, splitLines: splits
            ) ?? []
            transactions.append(contentsOf: effective.filter { visibleIDs.contains($0.id) })
        } while transactions.count == visibleCountBeforeLoad && canLoadMore
    }

}
