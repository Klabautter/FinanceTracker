import SwiftUI

/// Kategorieauswahl für Formulare, mit „Neue Kategorie …" am Ende: Überall,
/// wo man eine Kategorie zuordnet, lässt sich auch gleich eine anlegen. Die
/// neue Kategorie ist danach sofort ausgewählt.
struct CategorySelectionPicker: View {
    let title: String
    @Binding var selection: UUID?
    let categories: [Category]
    let dependencies: AppDependencies
    /// Eintrag für „keine Kategorie"; `nil` blendet ihn aus.
    var noneTitle: String? = Category.uncategorizedDisplayName
    var showsIcons = false
    /// Vorbelegung des Namens im Editor (z. B. der Händler).
    var suggestedName: String? = nil
    /// Damit der Aufrufer seine Kategorieliste neu laden kann.
    var onCreated: (Category) -> Void = { _ in }

    @State private var createdCategories: [Category] = []
    @State private var showsEditor = false

    /// Platzhalter-Tag für „Neue Kategorie …": wird nie zur Auswahl.
    private static let createTag = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!

    private var options: [Category] {
        let known = Set(categories.map(\.id))
        return categories + createdCategories.filter { !known.contains($0.id) }
    }

    var body: some View {
        Picker(title, selection: Binding(
            get: { selection },
            set: { newValue in
                if newValue == Self.createTag {
                    showsEditor = true
                } else {
                    selection = newValue
                }
            }
        )) {
            if let noneTitle {
                Text(noneTitle).tag(UUID?.none)
            }
            ForEach(options) { category in
                if showsIcons {
                    Label(category.name, systemImage: category.systemIconName)
                        .tag(UUID?.some(category.id))
                } else {
                    Text(category.name).tag(UUID?.some(category.id))
                }
            }
            Divider()
            Label("Neue Kategorie …", systemImage: "plus")
                .tag(UUID?.some(Self.createTag))
        }
        .sheet(isPresented: $showsEditor) {
            CategoryEditorSheet(
                dependencies: dependencies,
                editing: nil,
                onSaved: {},
                onCreated: { category in
                    createdCategories.append(category)
                    selection = category.id
                    onCreated(category)
                },
                suggestedName: suggestedName
            )
        }
    }
}
