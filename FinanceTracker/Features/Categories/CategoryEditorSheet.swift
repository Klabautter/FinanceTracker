import SwiftUI

struct CategoryEditorSheet: View {
    let dependencies: AppDependencies
    /// Existierende Kategorie = Bearbeiten, nil = Neu anlegen.
    let editing: Category?
    let onSaved: () -> Void
    /// Neu angelegte Kategorie zurückgeben, z. B. um sie direkt einer
    /// Buchung zuzuordnen.
    var onCreated: ((Category) -> Void)? = nil
    /// Vorbelegung für eine neue Kategorie (z. B. ein Vorschlag).
    var suggestedName: String? = nil
    var suggestedParentID: UUID? = nil

    @State private var model: CategoryEditorModel
    @Environment(\.dismiss) private var dismiss

    init(
        dependencies: AppDependencies,
        editing: Category?,
        onSaved: @escaping () -> Void,
        onCreated: ((Category) -> Void)? = nil,
        suggestedName: String? = nil,
        suggestedParentID: UUID? = nil
    ) {
        self.dependencies = dependencies
        self.editing = editing
        self.onSaved = onSaved
        self.onCreated = onCreated
        self.suggestedName = suggestedName
        self.suggestedParentID = suggestedParentID
        _model = State(initialValue: CategoryEditorModel(dependencies: dependencies, editing: editing))
    }

    var body: some View {
        @Bindable var model = model
        AdaptiveSheet(title: editing == nil ? String(localized: "Neue Kategorie") : String(localized: "Kategorie bearbeiten")) {
            Form {
                Section("Name") {
                    TextField("Kategoriename", text: $model.name)
                        .onSubmit { save() }
                }

                Section("Icon") {
                    // WP13: Kuratierter Picker statt roher SF-Symbol-Eingabe.
                    HStack {
                        Image(systemName: model.iconInput.isEmpty ? "tag" : model.iconInput)
                            .foregroundStyle(model.colorToken.color)
                            .frame(width: 28)
                        FinanceIconPicker(selection: $model.iconInput)
                    }
                }

                Section("Farbe") {
                    ColorSwatchPicker(
                        tokens: CategoryColorToken.allCases,
                        selection: $model.colorToken,
                        color: \.color,
                        name: \.localizedName,
                        size: 22
                    )
                    .padding(.vertical, 4)
                    .accessibilityLabel("Farbe: \(model.colorToken.localizedName)")
                }

                Section {
                    Picker("Übergeordnete Kategorie", selection: $model.parentID) {
                        Text("Hauptkategorie").tag(UUID?.none)
                        ForEach(model.parents.filter { $0.id != editing?.id }) { parent in
                            Text(parent.name).tag(UUID?.some(parent.id))
                        }
                    }
                    .disabled(editing != nil && editing?.parentID == nil && model.hasChildren(editing?.id))
                } footer: {
                    if editing != nil && editing?.parentID == nil && model.hasChildren(editing?.id) {
                        Text("Hauptkategorien mit Unterkategorien bleiben Hauptkategorien.")
                    } else {
                        Text("Unterkategorien sind diejenigen, die Transaktionen zugewiesen werden.")
                    }
                }

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppPalette.critical)
                }
            }
            .financeFormStyle()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(model.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { await model.load(suggestedName: suggestedName, suggestedParentID: suggestedParentID) }
        }
        #if os(macOS)
        .frame(width: 420, height: 440)
        #endif
    }

    private func save() {
        Task {
            guard let category = await model.save() else { return }
            onSaved()
            if editing == nil { onCreated?(category) }
            dismiss()
        }
    }

    nonisolated static func comparisonKey(_ name: String) -> String {
        CategoryEditorModel.comparisonKey(name)
    }
}

/// Zustand, Laden und Speichern des Kategorie-Editors (Rule 1).
@MainActor
@Observable
final class CategoryEditorModel {
    /// Nur, was dieses Model nutzt (Roadmap 7.4, `DependencyCapabilities`).
    typealias Dependencies = any HasCategoryRepository

    private let dependencies: Dependencies
    private let editing: Category?

    var name = ""
    var iconInput = "tag"
    var colorToken: CategoryColorToken = .blue
    var parentID: UUID?
    private(set) var parents: [Category] = []
    private(set) var existingNames: Set<String> = []
    private(set) var errorMessage: String?

    init(dependencies: Dependencies, editing: Category?) {
        self.dependencies = dependencies
        self.editing = editing
    }

    nonisolated static func comparisonKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func hasChildren(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return parents.contains { $0.parentID == id }
    }

    func load(suggestedName: String? = nil, suggestedParentID: UUID? = nil) async {
        do {
            let all = try await dependencies.categoryRepository.categories()
            parents = all.filter { $0.parentID == nil }.sorted { $0.name < $1.name }
            existingNames = Set(all.filter { $0.id != editing?.id }.map { Self.comparisonKey($0.name) })
            if editing == nil {
                if let suggestedName, name.isEmpty { name = suggestedName }
                if let suggestedParentID, parentID == nil {
                    parentID = suggestedParentID
                    if let parent = all.first(where: { $0.id == suggestedParentID }) {
                        iconInput = parent.systemIconName
                        colorToken = parent.colorToken
                    }
                }
            }
            if let editing {
                name = editing.name
                iconInput = editing.systemIconName
                colorToken = editing.colorToken
                parentID = editing.parentID
            }
        } catch {
            errorMessage = String(localized: "Kategorien konnten nicht geladen werden.")
        }
    }

    /// Speichert und liefert die Kategorie; `nil` bei Eingabe- oder Speicherfehler.
    func save() async -> Category? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Keine zweite Kategorie gleichen Namens, sonst wächst die Liste mit
        // Dubletten, die Analyse und Budgets zerteilen.
        guard !existingNames.contains(Self.comparisonKey(trimmed)) else {
            errorMessage = String(localized: "Eine Kategorie „\(trimmed)“ gibt es schon.")
            return nil
        }
        let category = Category(
            id: editing?.id ?? UUID(),
            name: trimmed,
            systemIconName: iconInput.isEmpty ? "tag" : iconInput,
            colorToken: colorToken,
            parentID: parentID
        )
        do {
            try await dependencies.categoryRepository.upsert([category])
            errorMessage = nil
            return category
        } catch {
            errorMessage = String(localized: "Speichern fehlgeschlagen.")
            return nil
        }
    }
}
