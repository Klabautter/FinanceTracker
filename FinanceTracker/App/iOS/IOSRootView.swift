import SwiftUI

struct IOSRootView: View {
    let dependencies: AppDependencies
    private static let primaryTabSections: Set<AppSection> = [.overview, .transactions, .analytics]

    var body: some View {
        TabView {
            Tab("Übersicht", systemImage: "square.grid.2x2") {
                NavigationStack {
                    DashboardView(dependencies: dependencies)
                }
            }

            Tab("Transaktionen", systemImage: "list.bullet.rectangle") {
                NavigationStack {
                    TransactionsView(dependencies: dependencies, pendingRoute: .constant(nil))
                }
            }

            Tab("Analyse", systemImage: "chart.pie") {
                NavigationStack {
                    AnalyticsView(dependencies: dependencies, pendingRoute: .constant(nil))
                }
            }

            Tab("Mehr", systemImage: "ellipsis.circle") {
                moreTab
            }
        }
    }

    private var moreTab: some View {
        NavigationStack {
            List {
                ForEach(AppSection.sidebarGroups.filter { group in
                    group.sections.contains { !Self.primaryTabSections.contains($0) }
                }, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.sections.filter { !Self.primaryTabSections.contains($0) }) { section in
                            NavigationLink {
                                destination(for: section)
                            } label: {
                                Label(section.title, systemImage: section.systemImage)
                            }
                        }
                    }
                }
                Section {
                    NavigationLink {
                        SettingsView(dependencies: dependencies)
                    } label: {
                        Label("Einstellungen", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Mehr")
        }
    }

    @ViewBuilder
    private func destination(for section: AppSection) -> some View {
        switch section {
        case .overview:
            DashboardView(dependencies: dependencies)
        case .transactions:
            TransactionsView(dependencies: dependencies, pendingRoute: .constant(nil))
        case .analytics:
            AnalyticsView(dependencies: dependencies, pendingRoute: .constant(nil))
        case .budgets:
            BudgetsView(dependencies: dependencies)
        case .pockets:
            PocketsView(dependencies: dependencies)
        case .accounts:
            AccountsView(dependencies: dependencies, pendingRoute: .constant(nil))
        case .categories:
            CategoriesView(dependencies: dependencies)
        case .recurring:
            FixkostenView(dependencies: dependencies)
        }
    }
}
