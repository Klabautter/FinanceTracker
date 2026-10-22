import SwiftUI

struct CategoriesView: View {
    private let dependencies: AppDependencies
    @State private var model: CategoriesModel
    @State private var rulePendingDeletion: CategoryRule?
    @State private var categoryPendingDeletion: Category?
    /// Eine item-basierte Sheet-Quelle statt mehrerer `isPresented`-Sheets
    /// (verhindert leere Ghost-Sheets unter macOS 26).
    @State private var activeSheet: CategoriesSheet?

    private enum CategoriesSheet: Identifiable {
        case categoryEditor(Category?)
        case ruleBuilder
        case reassign(Category)

        var id: String {
            switch self {
            case .categoryEditor(let category): "editor-\(category?.id.uuidString ?? "new")"
            case .ruleBuilder: "rule-builder"
            case .reassign(let category): "reassign-\(category.id.uuidString)"
            }
        }
    }

    /// Roadmap #52: Kategorien-Struktur und Automatisierung getrennt.
    private enum CategoriesTab: String, CaseIterable, Identifiable {
        case categories = "Kategorien"
        case automation = "Automatisierung"
        /// Tags sind ein Segment statt eines eigenen Sidebar-Bereichs
        /// (ein Verwaltungsscreen für Ordnungsbegriffe).
        case tags = "Tags"
        var id: Self { self }

        var title: String {
            switch self {
            case .categories: String(localized: "Kategorien")
            case .automation: String(localized: "Automatisierung")
            case .tags: String(localized: "Tags")
            }
        }
    }
    @State private var activeTab: CategoriesTab = .categories

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _model = State(initialValue: CategoriesModel(dependencies: dependencies))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Bereich", selection: $activeTab) {
                ForEach(CategoriesTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppLayout.pageHorizontalPadding)
            .padding(.bottom, AppSpacing.m)
            .accessibilityLabel("Bereich wählen")

            if activeTab == .tags {
                // Eigene ScrollView mit Lade-/Fehlerzustand, nicht verschachteln.
                TagsView(dependencies: dependencies, embedded: true)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.l) {
                    switch activeTab {
                    case .categories:
                        categoryStructureSection
                        ViewThatFits(in: .horizontal) {
                            categoryColumns(3).frame(minWidth: 3 * 300 + 2 * AppSpacing.l)
                            categoryColumns(2).frame(minWidth: 2 * 300 + AppSpacing.l)
                            categoryColumns(1)
                        }
                    case .automation:
                        rulesSection
                    case .tags:
                        EmptyView()
                    }
                }
                .padding(.horizontal, AppLayout.pageHorizontalPadding)
                .padding(.bottom, AppSpacing.xl)
                .frame(maxWidth: AppLayout.summaryMaximumWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("screen-ready-categories")
            }
        }
        .workspaceHeading(
            String(localized: "Kategorien & Regeln"),
            subtitle: String(localized: "Ordne deine Ausgaben, automatisiere Zuordnungen und markiere Buchungen mit Tags"),
            eyebrow: String(localized: "Organisation")
        )
        .workspaceCanvas()
        .workspaceToolbar {
            ToolbarItem(placement: .primaryAction) {
                switch activeTab {
                case .categories:
                    Button {
                        activeSheet = .categoryEditor(nil)
                    } label: {
                        Label("Neue Kategorie", systemImage: "plus.circle")
                    }
                    .accessibilityLabel("Neue Kategorie erstellen")
                    .help("Neue Kategorie erstellen")
                case .automation:
                    Button {
                        activeSheet = .ruleBuilder
                    } label: {
                        Label("Neue Regel", systemImage: "wand.and.stars")
                    }
                    .accessibilityLabel("Neue Regel erstellen")
                    .help("Neue Regel erstellen")
                case .tags:
                    // Tags werden direkt im Segment angelegt.
                    EmptyView()
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .categoryEditor(let category):
                CategoryEditorSheet(dependencies: model.dependencies, editing: category) {
                    Task { await model.load() }
                }
            case .ruleBuilder:
                RuleBuilderSheet(dependencies: model.dependencies) {
                    Task { await model.load() }
                }
            case .reassign(let source):
                reassignPickerSheet(source: source)
            }
        }
        .confirmationDialog(
            "Kategorie löschen?",
            isPresented: Binding(
                get: { categoryPendingDeletion != nil },
                set: { if !$0 { categoryPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Ohne Kategorie setzen", role: .destructive) {
                if let category = categoryPendingDeletion {
                    Task { await model.delete(category, reassignTo: nil) }
                }
                categoryPendingDeletion = nil
            }
            Button("Zu anderer Kategorie verschieben…") {
                let source = categoryPendingDeletion
                categoryPendingDeletion = nil
                if let source { activeSheet = .reassign(source) }
            }
            Button("Abbrechen", role: .cancel) {
                categoryPendingDeletion = nil
            }
        } message: {
            if let category = categoryPendingDeletion {
                Text(categoryDeleteMessage(for: category))
            }
        }
        .overlay {
            if model.isLoading, model.groups.isEmpty {
                LoadingStateView()
            } else if model.groups.isEmpty && model.errorMessage == nil && !model.isLoading {
                EmptyStateView(
                    title: String(localized: "Keine Kategorien"),
                    message: String(localized: "Es sind noch keine Kategorien vorhanden."),
                    systemImage: "tag"
                )
                .accessibilityIdentifier("screen-ready-categories")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = model.errorMessage {
                HStack(spacing: AppSpacing.m) {
                    InlineNotice(message: errorMessage, title: String(localized: "Kategorien konnten nicht geladen werden"), tone: .critical)
                    Button("Erneut versuchen") { Task { await model.load() } }
                }
                .padding(.horizontal, AppLayout.pageHorizontalPadding)
                .padding(.bottom, AppSpacing.s)
            }
        }
        .workspaceNavigationTitle(String(localized: "Kategorien & Regeln"))
        .refreshable { await model.load() }
        .task(id: model.dataRevision) { await model.load() }
        .confirmationDialog(
            "Regel löschen?",
            isPresented: Binding(
                get: { rulePendingDeletion != nil },
                set: { if !$0 { rulePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                if let rule = rulePendingDeletion {
                    Task { await model.deleteRule(rule) }
                }
                rulePendingDeletion = nil
            }
            Button("Abbrechen", role: .cancel) {
                rulePendingDeletion = nil
            }
        } message: {
            Text("Zukünftige Transaktionen werden nicht mehr automatisch zugeordnet.")
        }
    }

    /// Masonry: Gruppen werden reihum auf die jeweils kürzeste Spalte
    /// verteilt (Gewicht = Kopf + Unterkategorien), damit keine Lücken
    /// durch zeilenweise Höhenangleichung entstehen.
    private func categoryColumns(_ count: Int) -> some View {
        var columns = Array(repeating: [CategoryGroup](), count: count)
        var heights = Array(repeating: 0, count: count)
        for group in model.groups {
            let target = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[target].append(group)
            heights[target] += 2 + group.children.count
        }
        return HStack(alignment: .top, spacing: AppSpacing.l) {
            ForEach(columns.indices, id: \.self) { index in
                VStack(spacing: AppSpacing.l) {
                    ForEach(columns[index]) { group in
                        CategoryGroupRows(
                            group: group,
                            onEdit: { activeSheet = .categoryEditor($0) },
                            onDelete: { categoryPendingDeletion = $0 }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func categoryDeleteMessage(for category: Category) -> String {
        let count = model.transactionCount(for: category)
        return count == 1
            ? String(localized: "1 Transaktion verwendet diese Kategorie. Sie wird „Ohne Kategorie“ zugeordnet.")
            : String(localized: "\(count) Transaktionen verwenden diese Kategorie. Sie werden „Ohne Kategorie“ zugeordnet.")
    }

    private func reassignPickerSheet(source: Category) -> some View {
        AdaptiveSheet(title: String(localized: "Verschieben nach…")) {
            List {
                Group {
                    Section {
                        Text(categoryDeleteMessage(for: source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Neue Kategorie") {
                        ForEach(allSelectableCategories(excluding: source.id)) { candidate in
                            Button {
                                let target = candidate
                                Task {
                                    await model.delete(source, reassignTo: target.id)
                                    activeSheet = nil
                                }
                            } label: {
                                HStack(spacing: AppSpacing.s) {
                                    IconTile(systemName: candidate.systemIconName, color: candidate.colorToken.color, size: 24)
                                    Text(candidate.name)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        activeSheet = nil
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 380, height: 420)
        #endif
    }

    private func allSelectableCategories(excluding id: UUID) -> [Category] {
        model.groups
            .flatMap { [$0.parent] + $0.children.map(\.category) }
            .filter { $0.id != id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var categoryStructureSection: some View {
        Label("Unterkategorien ordnen Transaktionen zu. Hauptkategorien fassen sie zusammen.", systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var rulesSection: some View {
        PageSection(
            String(localized: "Automatische Zuordnung"),
            subtitle: String(localized: "Deine Regeln haben Vorrang vor den Standardregeln. Es greift die erste passende aktive Regel.")
        ) {
            if model.rules.isEmpty {
                Text("Noch keine Regeln. Lege über „Neue Regel“ in der Symbolleiste oder in den Transaktionsdetails eine an.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.rules) { rule in
                        ruleRow(rule)
                            .padding(.vertical, 8)
                        if rule.id != model.rules.last?.id { Divider() }
                    }
                }
            }

            Button {
                Task { await model.applyRulesToAllTransactions() }
            } label: {
                if model.isApplyingRules {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Wende Regeln an…")
                    }
                } else {
                    Label("Auf alle ohne Kategorie anwenden", systemImage: "wand.and.stars")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isApplyingRules || model.rules.isEmpty)

            if let message = model.applyResultMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } accessory: {
            EmptyView()
        }
    }

    private func ruleRow(_ rule: CategoryRule) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { rule.enabled },
                set: { _ in Task { await model.toggleRule(rule) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.conditionText(for: rule))
                        .font(.callout)
                        .lineLimit(1)
                    Text(model.ruleDetailText(for: rule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityLabel(rule.enabled
                ? Text("Regel \(model.conditionText(for: rule)), \(model.ruleDetailText(for: rule)), aktuell aktiv")
                : Text("Regel \(model.conditionText(for: rule)), \(model.ruleDetailText(for: rule)), aktuell aus"))

            Spacer()

            // Standardregeln gehören zum Systemkatalog und kämen beim nächsten
            // Katalog-Abgleich zurück; sie lassen sich nur deaktivieren.
            if rule.origin == .user {
                Button(role: .destructive) {
                    rulePendingDeletion = rule
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Regel löschen")
                .help("Regel löschen")
            }
        }
    }
}

private struct CategoryGroupRows: View {
    let group: CategoryGroup
    var onEdit: (Category) -> Void = { _ in }
    var onDelete: (Category) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppSpacing.m) {
                IconTile(systemName: group.parent.systemIconName, color: group.parent.colorToken.color, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.parent.name)
                        .font(.body.weight(.semibold))
                    (group.totalCount == 1 ? Text("1 Transaktion") : Text("\(group.totalCount) Transaktionen"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                categoryMenu(group.parent)
            }
            .padding(.bottom, group.children.isEmpty ? 0 : AppSpacing.s)
            .contentShape(Rectangle())
            .contextMenu { menuItems(group.parent) }

            ForEach(group.children) { child in
                Divider().padding(.leading, 46)
                HStack(spacing: AppSpacing.m) {
                    IconTile(systemName: child.category.systemIconName, color: child.category.colorToken.color, size: 24)
                        .padding(.leading, 5)
                    Text(child.category.name)
                        .font(.callout)
                    Spacer()
                    Text(String(child.ownCount))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    categoryMenu(child.category)
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .contextMenu { menuItems(child.category) }
            }
        }
        .financeCard(padding: AppSpacing.l)
    }

    @ViewBuilder
    private func menuItems(_ category: Category) -> some View {
        Button("Bearbeiten") { onEdit(category) }
        Divider()
        Button("Löschen", role: .destructive) { onDelete(category) }
    }

    private func categoryMenu(_ category: Category) -> some View {
        Menu {
            menuItems(category)
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        #if os(macOS)
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .help("Kategorie bearbeiten oder löschen")
        .accessibilityLabel("Aktionen für Kategorie \(category.name)")
    }
}
