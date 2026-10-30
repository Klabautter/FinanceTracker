import SwiftUI

struct MacRootView: View {
    let dependencies: AppDependencies
    @State private var navigationState = AppSectionNavigationState()
    @State private var dashboardModel: DashboardModel
    @State private var showsCommandPalette = false
    /// WP24: Ausstehende Palette-Deep-Links für die Ziel-Screens.
    @State private var pendingRoute: PaletteRoute?
    @Environment(\.openSettings) private var openSettings

    init(dependencies: AppDependencies, initialSection: AppSection = .overview) {
        self.dependencies = dependencies
        var navigation = AppSectionNavigationState()
        navigation.select(initialSection)
        _navigationState = State(initialValue: navigation)
        _dashboardModel = State(initialValue: DashboardModel(dependencies: dependencies))
    }

    private var selection: Binding<AppSection?> {
        Binding(
            get: { navigationState.selection },
            set: { if let section = $0 { navigationState.select(section) } }
        )
    }

    var body: some View {
        workspace
        // Halbbild auf dem 15"-MacBook (855 pt) soll gehen, kleiner nicht:
        // Der Inhalt ist für diese Breite gebaut; schmaler quetscht sich die
        // Tabelle und das Layout wird teurer. 840 lässt Platz für die Ränder
        // beim Andocken.
        .frame(minWidth: 840, minHeight: 600)
        // Keine Rollbalken, auch wenn macOS sie dauerhaft einblenden will:
        // Scrollen geht per Trackpad, Mausrad und Tastatur.
        .scrollIndicators(.never)
    }

    private var reviewBadgeCount: Int? {
        guard dashboardModel.hasLoadedReviewSummary else { return nil }
        let count = dashboardModel.reviewSummary.totalCount
        return count > 0 ? count : nil
    }

    private var workspace: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(AppSection.sidebarGroups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            Label(section.sidebarTitle, systemImage: section.systemImage)
                                .badge(section == .transactions ? (reviewBadgeCount ?? 0) : 0)
                                .tag(section)
                            .accessibilityIdentifier("sidebar-\(section.identifierName)")
                        }
                    }
                }
                Section {
                    Button {
                        openSettings()
                    } label: {
                        Label(String(localized: "Einstellungen", comment: "Sidebar-Eintrag: Einstellungen öffnen"), systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Einstellungen", comment: "Sidebar-Eintrag: Einstellungen öffnen"))
                    .accessibilityIdentifier("sidebar-Einstellungen")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detailView
                .navigationTitle(navigationState.selection.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { PrivacyToggleToolbarButton() }
                }
        }
        // WP22: ⌘K läuft über die native Command-Bar (FinanceCommands),
        // der unsichtbare 0×0-Shortcut-Button ist entfernt.
        .focusedSceneValue(\.openCommandPalette, OpenCommandPaletteAction {
            showsCommandPalette = true
        })
        .focusedSceneValue(\.openReviewQueue, OpenReviewQueueAction {
            openReviewQueue()
        })
        .focusedSceneValue(\.selectSection, SelectSectionAction { section in
            navigationState.select(section)
        })
        .sheet(isPresented: $showsCommandPalette) {
            CommandPaletteView(
                dependencies: dependencies,
                reviewCount: dashboardModel.hasLoadedReviewSummary ? dashboardModel.reviewSummary.totalCount : nil,
                onSelect: { route in
                    handleRoute(route)
                }
            )
        }
    }

    /// WP24: Deep-Link-Routing: jedes Ergebnis zielt auf sein exaktes Ziel
    /// statt nur auf einen Sektionswechsel (§172).
    private func handleRoute(_ route: PaletteRoute) {
        switch route {
        case .section(let section):
            navigationState.select(section)
        case .reviewQueue:
            openReviewQueue()
        case .settings:
            openSettings()
        case .transaction(let id):
            navigationState.select(.transactions)
            pendingRoute = .transaction(id)
        case .account(let id):
            navigationState.select(.accounts)
            pendingRoute = .account(id)
        case .category(let id):
            navigationState.select(.analytics)
            pendingRoute = .category(id)
        case .tag(let id):
            navigationState.select(.transactions)
            pendingRoute = .tag(id)
        case .transactionsMonth, .transactionsScope:
            // MacUX-Audit: Cashflow-Klick → Monatstransaktionen.
            navigationState.select(.transactions)
            pendingRoute = route
        }
    }

    private func openReviewQueue() {
        navigationState.select(.transactions)
        pendingRoute = .reviewQueue
    }

    @ViewBuilder
    private var detailView: some View {
        // Die Bereiche liegen als Overlay über einer leeren Fläche: Sie
        // bekommen deren Größe zugewiesen, statt dass die Fenstergröße bei
        // jedem Wechsel über alle geöffneten Bereiche neu vermessen wird.
        Color.clear
            .overlay(alignment: .topLeading) {
                ForEach(navigationState.mountedSections) { section in
                    MountedSection(section: section, isActive: navigationState.selection == section) {
                        sectionView(for: section)
                    }
                    .equatable()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func sectionView(for section: AppSection) -> some View {
        switch section {
        case .overview:
            // Dashboard und Transaktionsbereich teilen eine einzige geladene
            // Review-Zusammenfassung für Palette und Toolbar.
            DashboardView(
                dependencies: dependencies,
                model: dashboardModel,
                onShowAllTransactions: { navigationState.select(.transactions) },
                onShowTransactionsInMonth: { interval in
                    navigationState.select(.transactions)
                    pendingRoute = .transactionsMonth(interval)
                },
                onShowBudgets: { navigationState.select(.budgets) },
                onShowRecurring: { navigationState.select(.recurring) }
            )
        case .transactions:
            TransactionsView(
                dependencies: dependencies,
                pendingRoute: $pendingRoute,
                reviewCount: dashboardModel.hasLoadedReviewSummary ? dashboardModel.reviewSummary.totalCount : nil
            )
        case .analytics:
            AnalyticsView(dependencies: dependencies, pendingRoute: $pendingRoute, onOpenRecurring: {
                navigationState.select(.recurring)
            }, onShowTransactionsInMonth: { scope in
                navigationState.select(.transactions)
                pendingRoute = .transactionsScope(scope)
            })
        case .budgets:
            BudgetsView(dependencies: dependencies)
        case .pockets:
            PocketsView(dependencies: dependencies)
        case .accounts:
            AccountsView(dependencies: dependencies, pendingRoute: $pendingRoute)
        case .categories:
            CategoriesView(dependencies: dependencies)
        case .recurring:
            FixkostenView(dependencies: dependencies)
        }
    }
}

/// Ein geöffneter Bereich bleibt im Hintergrund erhalten (Auswahl,
/// Scrollposition, Filter). Beim Wechsel werden nur der verlassene und der
/// neue Bereich neu berechnet; alle anderen sind unverändert und werden
/// übersprungen. Änderungen an beobachteten Modellen wirken weiterhin.
private struct MountedSection<Content: View>: View, Equatable {
    let section: AppSection
    let isActive: Bool
    @ViewBuilder let content: () -> Content

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.section == rhs.section && lhs.isActive == rhs.isActive
    }

    /// Größe, in der ausgeblendete Bereiche stehen bleiben (siehe body).
    private static var parkedSize: CGSize { CGSize(width: 1_000, height: 800) }

    var body: some View {
        content()
            .environment(\.isWorkspaceActive, isActive)
            // Ausgeblendete Bereiche bekommen eine feste Größe: Sonst
            // vermisst SwiftUI bei jeder Größenänderung (z. B. jedem Frame
            // der Seitenleisten-Animation) alle geladenen Bereiche neu,
            // Diagramme und Tabellen, die niemand sieht.
            .frame(
                width: isActive ? nil : Self.parkedSize.width,
                height: isActive ? nil : Self.parkedSize.height,
                alignment: .topLeading
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}
