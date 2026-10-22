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

    @State private var name = ""
    @State private var iconInput = "tag"
    @State private var colorToken: CategoryColorToken = .blue
    @State private var parentID: UUID?
    @State private var parents: [Category] = []
    @State private var existingNames: Set<String> = []
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AdaptiveSheet(title: editing == nil ? String(localized: "Neue Kategorie") : String(localized: "Kategorie bearbeiten")) {
            Form {
                Section("Name") {
                    TextField("Kategoriename", text: $name)
                        .onSubmit { save() }
                }

                Section("Icon") {
                    // WP13: Kuratierter Picker statt roher SF-Symbol-Eingabe.
                    HStack {
                        Image(systemName: iconInput.isEmpty ? "tag" : iconInput)
                            .foregroundStyle(colorToken.color)
                            .frame(width: 28)
                        FinanceIconPicker(selection: $iconInput)
                    }
                }

                Section("Farbe") {
                    ColorSwatchPicker(
                        tokens: CategoryColorToken.allCases,
                        selection: $colorToken,
                        color: \.color,
                        name: \.localizedName,
                        size: 22
                    )
                    .padding(.vertical, 4)
                    .accessibilityLabel("Farbe: \(colorToken.localizedName)")
                }

                Section {
                    Picker("Übergeordnete Kategorie", selection: $parentID) {
                        Text("Hauptkategorie").tag(UUID?.none)
                        ForEach(parents.filter { $0.id != editing?.id }) { parent in
                            Text(parent.name).tag(UUID?.some(parent.id))
                        }
                    }
                    .disabled(editing != nil && editing?.parentID == nil && hasChildren(editing?.id))
                } footer: {
                    if editing != nil && editing?.parentID == nil && hasChildren(editing?.id) {
                        Text("Hauptkategorien mit Unterkategorien bleiben Hauptkategorien.")
                    } else {
                        Text("Unterkategorien sind diejenigen, die Transaktionen zugewiesen werden.")
                    }
                }

                if let errorMessage {
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
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { await loadParents() }
        }
        #if os(macOS)
        .frame(width: 420, height: 440)
        #endif
    }

    nonisolated static func comparisonKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func hasChildren(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return parents.contains { $0.parentID == id }
    }

    private func loadParents() async {
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

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Keine zweite Kategorie gleichen Namens, sonst wächst die Liste mit
        // Dubletten, die Analyse und Budgets zerteilen.
        guard !existingNames.contains(Self.comparisonKey(trimmed)) else {
            errorMessage = String(localized: "Eine Kategorie „\(trimmed)“ gibt es schon.")
            return
        }
        let category = Category(
            id: editing?.id ?? UUID(),
            name: trimmed,
            systemIconName: iconInput.isEmpty ? "tag" : iconInput,
            colorToken: colorToken,
            parentID: parentID
        )
        Task {
            do {
                try await dependencies.categoryRepository.upsert([category])
                onSaved()
                if editing == nil { onCreated?(category) }
                dismiss()
            } catch {
                errorMessage = String(localized: "Speichern fehlgeschlagen.")
            }
        }
    }
}
