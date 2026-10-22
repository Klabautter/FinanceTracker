import SwiftUI

/// Command Palette (Roadmap #158–160, ⌘K): schnelle Suche + Navigation.
struct CommandPaletteView: View {
    let dependencies: AppDependencies
    let reviewCount: Int?
    /// Wird bei Auswahl einer Sektion gerufen (Navigation im Root).
    /// WP24: Typed Deep-Link-Route (Transaktion/Konto/Kategorie/Tag mit ID).
    let onSelect: (PaletteRoute) -> Void

    @State private var model: CommandPaletteModel?
    @State private var query = ""
    @State private var transactionResults: [CommandPaletteModel.Entry] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    /// Per Tastatur markierter Treffer (↑/↓, Return öffnet ihn).
    @State private var highlightedIndex = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyPresentationState.self) private var privacyState

    var body: some View {
        #if os(macOS)
        // Eigener Kopf statt NavigationStack + `.searchable`: Dessen Chrome
        // setzt das Suchfeld in macOS-Sheets klein in die Titelleiste, über
        // den Titel. Die Palette ist ein Suchfeld mit Ergebnissen darunter.
        withLifecycle(
            VStack(spacing: 0) {
                HStack(spacing: AppSpacing.s) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Bereiche, Konten, Kategorien, Buchungen suchen", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($searchFocused)
                        .accessibilityLabel("Suchen")
                        .onSubmit { activateHighlighted() }
                        .onKeyPress(.downArrow) {
                            highlightedIndex = min(highlightedIndex + 1, max(visibleEntries.count - 1, 0))
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            highlightedIndex = max(highlightedIndex - 1, 0)
                            return .handled
                        }
                    Button("Abbrechen") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.small)
                }
                .padding(.horizontal, AppSpacing.l)
                .padding(.vertical, AppSpacing.m)
                Divider()
                resultsList
            }
            .background(AppPalette.canvas)
        )
        .frame(width: 520, height: 480)
        #else
        withLifecycle(
            NavigationStack {
                resultsList
                    .navigationTitle("Suchen")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Abbrechen") { dismiss() }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .searchable(text: $query, prompt: "Suchen")
            .focused($searchFocused)
        )
        #endif
    }

    private var resultsList: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section("Bereiche") {
                    ForEach(navigationEntries) { entry in
                        row(entry)
                    }
                }
            } else {
                if !filteredNavigationEntries.isEmpty {
                    Section("Bereiche") {
                        ForEach(filteredNavigationEntries) { entry in
                            row(entry)
                        }
                    }
                }
                let accountResults = model?.accountEntries(query: query) ?? []
                if !accountResults.isEmpty {
                    Section("Konten") {
                        ForEach(accountResults) { entry in
                            row(entry)
                        }
                    }
                }
                let categoryResults = model?.categoryEntries(query: query) ?? []
                if !categoryResults.isEmpty {
                    Section("Kategorien") {
                        ForEach(categoryResults) { entry in
                            row(entry)
                        }
                    }
                }
                let tagResults = model?.tagEntries(query: query) ?? []
                if !tagResults.isEmpty {
                    Section("Tags") {
                        ForEach(tagResults) { entry in
                            row(entry)
                        }
                    }
                }
                if !transactionResults.isEmpty {
                    Section("Transaktionen") {
                        ForEach(transactionResults) { entry in
                            row(entry)
                        }
                    }
                }

                if allResultCount == 0, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Keine Treffer für „\(query)“.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Debounced Transaktionssuche und Erstladung, für beide Plattformen.
    private func withLifecycle(_ content: some View) -> some View {
        content
            .onChange(of: query) { _, newValue in
                highlightedIndex = 0
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    transactionResults = await model?.transactionEntries(query: newValue) ?? []
                }
            }
            .task {
                let paletteModel = CommandPaletteModel(dependencies: dependencies, privacyState: privacyState)
                model = paletteModel
                await paletteModel.loadStaticEntries()
                searchFocused = true
            }
    }

    private var staticSections: [CommandPaletteModel.Entry] {
        model?.sectionEntries() ?? []
    }

    private var navigationEntries: [CommandPaletteModel.Entry] {
        model?.navigationEntries(reviewCount: reviewCount) ?? []
    }

    private var filteredNavigationEntries: [CommandPaletteModel.Entry] {
        guard let model else { return [] }
        return model.navigationEntries(reviewCount: reviewCount).filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var allResultCount: Int {
        guard let model else { return 0 }
        return filteredNavigationEntries.count
            + model.accountEntries(query: query).count
            + model.categoryEntries(query: query).count
            + model.tagEntries(query: query).count
            + transactionResults.count
    }

    /// Alle Treffer in Anzeige-Reihenfolge: Grundlage der Tastaturbedienung.
    private var visibleEntries: [CommandPaletteModel.Entry] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return navigationEntries }
        guard let model else { return [] }
        return filteredNavigationEntries
            + model.accountEntries(query: query)
            + model.categoryEntries(query: query)
            + model.tagEntries(query: query)
            + transactionResults
    }

    private var highlightedEntryID: String? {
        let entries = visibleEntries
        return entries.indices.contains(highlightedIndex) ? entries[highlightedIndex].id : nil
    }

    private func activateHighlighted() {
        let entries = visibleEntries
        guard entries.indices.contains(highlightedIndex) else { return }
        activate(entries[highlightedIndex])
    }

    private func activate(_ entry: CommandPaletteModel.Entry) {
        switch entry.kind {
        case .section(let section):
            onSelect(.section(section))
        case .reviewQueue:
            onSelect(.reviewQueue)
        case .settings:
            onSelect(.settings)
        case .transaction(let txn):
            // WP24: Exaktes Deep-Link-Ziel statt nur Sektionswechsel.
            onSelect(.transaction(txn.id))
        case .account(let account):
            onSelect(.account(account.id))
        case .category(let category):
            onSelect(.category(category.id))
        case .tag(let tag):
            onSelect(.tag(tag.id))
        }
        dismiss()
    }

    private func row(_ entry: CommandPaletteModel.Entry) -> some View {
        let isHighlighted = entry.id == highlightedEntryID
        return Button {
            activate(entry)
        } label: {
            HStack(spacing: AppSpacing.m) {
                let icon = icon(for: entry)
                IconTile(systemName: icon.name, color: icon.color, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.callout.weight(.medium))
                    if let subtitle = entry.subtitle, subtitle != String(localized: "Bereich") {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // Das Return-Symbol zeigt, welchen Treffer die Eingabetaste öffnet.
                if isHighlighted {
                    Image(systemName: "return")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isHighlighted
                ? RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08))
                : nil
        )
    }

    private func icon(for entry: CommandPaletteModel.Entry) -> (name: String, color: Color) {
        switch entry.kind {
        case .section(let section): (section.systemImage, AppPalette.brand)
        case .reviewQueue: ("checklist", AppPalette.warning)
        case .settings: ("gearshape", Color.secondary)
        case .account: ("building.columns", AppPalette.information)
        case .category(let category): (category.systemIconName, category.colorToken.color)
        case .tag(let tag): ("tag.fill", tag.colorToken.color)
        case .transaction(let transaction):
            (transaction.amount.amount > 0 ? "arrow.down.left" : "arrow.up.right",
             transaction.amount.amount > 0 ? AppPalette.positive : Color.secondary)
        }
    }
}
