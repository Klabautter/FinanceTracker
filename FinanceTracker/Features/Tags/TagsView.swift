import SwiftUI

struct TagChip: View {
    let tag: Tag
    var showsColorDot: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            if showsColorDot {
                Circle()
                    .fill(tag.colorToken.color)
                    .frame(width: 7, height: 7)
            }
            Text(tag.name)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tag.colorToken.color.opacity(0.14)))
        .foregroundStyle(.primary)
        .accessibilityLabel("Tag \(tag.name)")
    }
}

struct TagsView: View {
    @State private var model: TagsModel
    @State private var newTagName = ""
    @State private var newTagColor: TagColorToken = .blue
    @State private var tagPendingDeletion: Tag?
    @State private var editingTagID: UUID?
    @State private var editingName = ""
    /// Eingebettet (Segment in „Kategorien & Regeln"): kein eigener Seitenkopf.
    private let embedded: Bool

    init(dependencies: AppDependencies, embedded: Bool = false) {
        self.embedded = embedded
        _model = State(initialValue: TagsModel(dependencies: dependencies))
    }

    var body: some View {
        Group {
            if embedded {
                scrollContent
            } else {
                scrollContent
                    .workspaceHeading(
                        String(localized: "Tags"),
                        subtitle: String(localized: "Eigene Markierungen für deine Transaktionen"),
                        eyebrow: String(localized: "Organisation")
                    )
                    .workspaceNavigationTitle(String(localized: "Tags"))
            }
        }
        .workspaceCanvas()
        .overlay {
            if model.isLoading, model.tags.isEmpty {
                LoadingStateView()
            }
        }
        .refreshable { await model.load() }
        .task(id: model.dataRevision) { await model.load() }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.l) {
                PageSection(
                    String(localized: "Neuer Tag"),
                    subtitle: String(localized: "Zum Beispiel „dienstlich“ oder „erstattbar“. Mehrere Tags pro Transaktion sind möglich.")
                ) {
                    VStack(alignment: .leading, spacing: AppSpacing.m) {
                        HStack(spacing: AppSpacing.m) {
                            TextField("Tag-Name", text: $newTagName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { createTag() }
                                .accessibilityLabel("Name des neuen Tags")
                                .frame(maxWidth: 320)
                            Button("Erstellen", systemImage: "plus") { createTag() }
                                .buttonStyle(.borderedProminent)
                                .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityLabel("Tag erstellen")
                        }
                        ColorSwatchPicker(
                            tokens: TagColorToken.allCases,
                            selection: $newTagColor,
                            color: \.color,
                            name: \.localizedName
                        )
                        .accessibilityLabel("Farbe des neuen Tags")
                    }
                }
                if let errorMessage = model.errorMessage {
                    HStack(spacing: AppSpacing.m) {
                        InlineNotice(message: errorMessage, title: String(localized: "Tags konnten nicht geladen werden"), tone: .critical)
                        Button("Erneut versuchen") { Task { await model.load() } }
                    }
                }
                PageSection(
                    String(localized: "Deine Tags"),
                    subtitle: model.tags.isEmpty ? nil : (model.tags.count == 1 ? String(localized: "1 Tag") : String(localized: "\(model.tags.count) Tags"))
                ) {
                    if model.tags.isEmpty && !model.isLoading {
                        Text("Noch keine Tags. Erstelle deinen ersten Tag oben.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("screen-ready-tags")
                    }
                    VStack(spacing: 0) {
                        ForEach(model.tags) { tag in
                            tagRow(tag)
                                .accessibilityIdentifier("screen-ready-tags")
                            if tag.id != model.tags.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(.horizontal, AppLayout.pageHorizontalPadding)
            .padding(.bottom, AppSpacing.l)
            .frame(maxWidth: AppLayout.summaryMaximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "Tag löschen?",
            isPresented: Binding(
                get: { tagPendingDeletion != nil },
                set: { if !$0 { tagPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                if let tag = tagPendingDeletion {
                    Task { await model.delete(tag) }
                }
                tagPendingDeletion = nil
            }
            Button("Abbrechen", role: .cancel) {
                tagPendingDeletion = nil
            }
        } message: {
            if let tag = tagPendingDeletion {
                Text("Dieser Tag ist \(model.usageCount(for: tag.id)) Transaktionen zugewiesen. Die Transaktionen selbst bleiben unverändert.")
            }
        }
    }

    private func tagRow(_ tag: Tag) -> some View {
        HStack(spacing: AppSpacing.m) {
            IconTile(systemName: "tag.fill", color: tag.colorToken.color, size: 28)

            if editingTagID == tag.id {
                TextField("Tag-Name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onSubmit { commitRename(tag) }
            } else {
                Text(tag.name)
                    .fontWeight(.medium)
            }

            Spacer()
            let count = model.usageCount(for: tag.id)
            (count == 1 ? Text("1 Transaktion") : Text("\(count) Transaktionen"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                Menu("Farbe") {
                    ForEach(TagColorToken.allCases, id: \.self) { token in
                        Button {
                            var updated = tag
                            updated.colorToken = token
                            Task { await model.update(updated) }
                        } label: {
                            HStack {
                                Circle().fill(token.color).frame(width: 10, height: 10)
                                Text(token.localizedName)
                                if tag.colorToken == token {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Button(editingTagID == tag.id ? String(localized: "Umbenennen abschließen") : String(localized: "Umbenennen")) {
                    if editingTagID == tag.id {
                        commitRename(tag)
                    } else {
                        editingTagID = tag.id
                        editingName = tag.name
                    }
                }

                Divider()
                Button("Löschen", role: .destructive) {
                    tagPendingDeletion = tag
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Aktionen für Tag \(tag.name)")
            .help("Tag bearbeiten oder löschen")
        }
        .padding(.vertical, AppSpacing.s)
    }

    private func commitRename(_ tag: Tag) {
        let newName = editingName.trimmingCharacters(in: .whitespaces)
        editingTagID = nil
        editingName = ""
        guard !newName.isEmpty, newName != tag.name else { return }
        var updated = tag
        updated.name = newName
        Task { await model.update(updated) }
    }

    private func createTag() {
        let color = newTagColor
        let name = newTagName
        newTagName = ""
        Task { await model.createTag(named: name, colorToken: color) }
    }
}

private extension TagColorToken {
    var localizedName: String {
        switch self {
        case .blue: String(localized: "Blau")
        case .green: String(localized: "Grün")
        case .orange: String(localized: "Orange")
        case .purple: String(localized: "Violett")
        case .red: String(localized: "Rot")
        case .teal: String(localized: "Türkis")
        case .yellow: String(localized: "Gelb")
        case .indigo: String(localized: "Indigo")
        case .gray: String(localized: "Grau")
        }
    }
}
