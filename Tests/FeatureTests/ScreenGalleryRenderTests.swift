#if DEBUG && os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import FinanceTracker

/// Statische Offscreen-Galerie aller Hauptbereiche und Dialoge. Kein
/// Durchklick-Test: Views werden in einem nie angezeigten Fenster gehostet
/// und über `cacheDisplay` gerastert. Nur aktiv, wenn
/// `TEST_RUNNER_SCREEN_GALLERY_DIR` gesetzt ist; Daten stammen aus dem
/// In-Memory-Preview-Store.
@MainActor
@Suite("ScreenGalleryRender", .serialized)
struct ScreenGalleryRenderTests {

    private var outputDirectory: URL? {
        let env = ProcessInfo.processInfo.environment
        return (env["TEST_RUNNER_SCREEN_GALLERY_DIR"] ?? env["SCREEN_GALLERY_DIR"]).map(URL.init(fileURLWithPath:))
    }

    @Test("Alle Bereiche und Dialoge rendern offscreen")
    func rendersGallery() async throws {
        guard outputDirectory != nil else { return }
        let dependencies = PreviewDependencies.dependencies()
        let privacy = PrivacyPresentationState(defaults: scratchDefaults())
        let schemes: [ColorScheme] = (ProcessInfo.processInfo.environment["SCREEN_GALLERY_DARK"] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_SCREEN_GALLERY_DARK"]) == "1" ? [.light, .dark] : [.light]

        for scheme in schemes {
            let suffix = scheme == .dark ? "-dark" : ""
            for section in AppSection.allCases {
                try await render(
                    MacRootView(dependencies: dependencies, initialSection: section),
                    size: CGSize(width: 1_320, height: 860),
                    scheme: scheme,
                    privacy: privacy,
                    name: "screen-\(section.rawValue)\(suffix)"
                )
            }

            // Leerzustände: frischer Store ohne Transaktionen, aber mit
            // Systemkategorien (wie nach „alles löschen").
            let emptyStore = try SwiftDataStore(inMemory: true)
            let emptyDependencies = AppDependencies.make(container: emptyStore.container, baseCurrency: .eur)
            await SystemCatalogSeeder(dependencies: emptyDependencies).seedIfNeeded()
            for section in AppSection.allCases {
                try await render(
                    MacRootView(dependencies: emptyDependencies, initialSection: section),
                    size: CGSize(width: 1_320, height: 860),
                    scheme: scheme,
                    privacy: privacy,
                    name: "empty-\(section.rawValue)\(suffix)"
                )
            }

            let transactions = try await dependencies.transactionRepository.recentTransactions(limit: 20)
            let transaction = try #require(transactions.first { $0.amount.amount < 0 })
            let accounts = try await dependencies.accountRepository.accounts()
            let account = try #require(accounts.first)
            let commitments = try await dependencies.recurringCommitmentRepository.commitments()
            let categories = try await dependencies.categoryRepository.categories()
            let budgetsModel = BudgetsModel(dependencies: dependencies)
            await budgetsModel.load()
            let pocketsModel = PocketsModel(dependencies: dependencies)
            await pocketsModel.load()
            let month = Calendar.current.dateInterval(of: .month, for: Date())!

            var dialogs: [(String, AnyView, CGSize)] = [
                ("add-transaction", AnyView(AddTransactionSheet(dependencies: dependencies, onSaved: {})), CGSize(width: 560, height: 640)),
                ("transaction-detail", AnyView(TransactionDetailSheet(transactionID: transaction.id, dependencies: dependencies)), CGSize(width: 640, height: 820)),
                ("transaction-split", AnyView(TransactionSplitSheet(parent: transaction, dependencies: dependencies, onSaved: {})), CGSize(width: 560, height: 600)),
                ("review-queue", AnyView(ReviewQueueView(dependencies: dependencies)), CGSize(width: 820, height: 640)),
                ("command-palette", AnyView(CommandPaletteView(dependencies: dependencies, reviewCount: 3, onSelect: { _ in })), CGSize(width: 640, height: 520)),
                ("settings", AnyView(SettingsView(dependencies: dependencies)), CGSize(width: 680, height: 720)),
                ("add-data-source", AnyView(AddDataSourceView(dependencies: dependencies, onDismiss: {})), CGSize(width: 620, height: 600)),
                ("bank-connect", AnyView(BankConnectView(dependencies: dependencies, onDone: {})), CGSize(width: 640, height: 720)),
                ("import", AnyView(ImportView(dependencies: dependencies)), CGSize(width: 720, height: 720)),
                ("account-detail", AnyView(AccountDetailSheet(account: account, connectionName: "Enable Banking", lastSync: Date(), dependencies: dependencies)), CGSize(width: 640, height: 720)),
                ("category-editor", AnyView(CategoryEditorSheet(dependencies: dependencies, editing: nil, onSaved: {})), CGSize(width: 560, height: 640)),
                ("account-editor", AnyView(AccountEditorSheet(dependencies: dependencies, onSaved: {})), CGSize(width: 520, height: 560)),
                ("rule-builder", AnyView(RuleBuilderSheet(dependencies: dependencies, onSaved: {})), CGSize(width: 560, height: 600)),
                ("add-budget", AnyView(AddBudgetSheet(dependencies: dependencies, editing: nil, onSaved: {})), CGSize(width: 560, height: 720)),
                ("pocket-editor", AnyView(PocketEditorSheet(model: pocketsModel, editing: nil)), CGSize(width: 560, height: 640)),
                ("recurring-create", AnyView(FixkostenCreateSheet(dependencies: dependencies, onSaved: {})), CGSize(width: 560, height: 560)),
                ("merchant-detail", AnyView(MerchantDetailSheet(merchantName: transaction.effectiveMerchantName, scope: AnalyticsScope(rangeTitle: "Dieser Monat", query: TransactionQuery(dateInterval: month), accountNames: [], categoryNames: [], source: nil), dependencies: dependencies)), CGSize(width: 640, height: 640)),
                ("category-drilldown", AnyView(CategoryDrilldownSheet(categoryID: categories.first?.id, categoryName: categories.first?.name ?? "", dateInterval: month, currency: .eur, dependencies: dependencies)), CGSize(width: 640, height: 640)),
            ]
            if let commitment = commitments.first {
                dialogs.append(("recurring-detail", AnyView(FixkostenDetailSheet(commitment: commitment, dependencies: dependencies, onChanged: {})), CGSize(width: 640, height: 760)))
            }
            if let progress = budgetsModel.progresses.first {
                dialogs.append(("budget-detail", AnyView(BudgetDetailSheet(progress: progress, dependencies: dependencies, onEdit: {})), CGSize(width: 640, height: 760)))
            }
            for (name, view, size) in dialogs {
                try await render(view, size: size, scheme: scheme, privacy: privacy, name: "dialog-\(name)\(suffix)")
            }
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, privacy: PrivacyPresentationState, name: String) async throws {
        let root = view
            .environment(privacy)
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Laden der `.task`-Modifier abwarten.
        for _ in 0..<12 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory!.appendingPathComponent("\(name).png"))
        window.contentView = nil
        window.close()
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "ScreenGallery-\(UUID().uuidString)")!
        suite.set(false, forKey: PrivacyPresentationState.defaultsKey)
        return suite
    }
}
#endif
