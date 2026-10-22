import SwiftUI

struct CategoryPickerMenu: View {
    let currentCategory: Category?
    let categories: [Category]
    let onSelect: (UUID?) -> Void

    private var parentCategories: [Category] {
        categories.filter { $0.parentID == nil }
    }

    private func children(of parent: Category) -> [Category] {
        categories.filter { $0.parentID == parent.id }
    }

    var body: some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                Label(Category.uncategorizedDisplayName, systemImage: "tag.slash")
            }

            ForEach(parentCategories) { parent in
                Section(parent.name) {
                    // Leaf-only (Roadmap #43): Parent-Kategorien dienen der
                    // Aggregation und sind nicht direkt zuweisbar. Eltern
                    // ohne Kinder erscheinen als wählbares Leaf.
                    let children = children(of: parent)
                    if children.isEmpty {
                        Button {
                            onSelect(parent.id)
                        } label: {
                            Label(parent.name, systemImage: parent.systemIconName)
                        }
                    } else {
                        ForEach(children) { child in
                            Button {
                                onSelect(child.id)
                            } label: {
                                Label(child.name, systemImage: child.systemIconName)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentCategory?.systemIconName ?? "tag.slash")
                    .foregroundStyle(currentCategory?.colorToken.color ?? .secondary)
                Text(currentCategory?.name ?? Category.uncategorizedDisplayName)
            }
            .contentShape(Rectangle())
        } primaryAction: {}
        .accessibilityLabel(
            "Kategorie ändern. Aktuell: \(currentCategory?.name ?? Category.uncategorizedDisplayName)"
        )
    }
}

extension Category {
    static var uncategorizedDisplayName: String { String(localized: "Ohne Kategorie") }
}
