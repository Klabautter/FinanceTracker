import Foundation

@MainActor
@Observable
final class TagsModel {
    let dependencies: AppDependencies

    private(set) var tags: [Tag] = []
    private(set) var usageCounts: [UUID: Int] = [:]
    /// Laden (AGENTS #37); Speicher-, Lösch- und Eingabefehler stehen
    /// getrennt in `actionError`.
    private(set) var loadState: LoadState = .idle
    private(set) var actionError: String?
    var isLoading: Bool { loadState.isLoading }

    var dataRevision: Int { dependencies.changeTracker.revision }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func load() async {
        guard !isLoading else { return }
        loadState = .loading
        var failure: String?
        defer { loadState = failure.map { .failed($0) } ?? .loaded }

        do {
            tags = try await dependencies.tagRepository.tags()
            usageCounts = try await loadUsageCounts()
        } catch {
            failure = String(localized: "Tags konnten nicht geladen werden.")
        }
    }

    /// WP19: Nutzungsanzahl pro Tag per Join-Row-Pushdown (kein
    /// Annotations-Fullload mehr).
    private func loadUsageCounts() async throws -> [UUID: Int] {
        try await dependencies.tagRepository.usageCounts()
    }

    func createTag(named name: String, colorToken: TagColorToken = .blue) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let tag = Tag(name: trimmed, colorToken: colorToken)
        do {
            try await dependencies.tagRepository.upsert([tag])
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            actionError = String(localized: "Tag konnte nicht erstellt werden.")
        }
    }

    func update(_ tag: Tag) async {
        do {
            try await dependencies.tagRepository.upsert([tag])
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            actionError = String(localized: "Tag konnte nicht gespeichert werden.")
        }
    }

    /// Löscht den Tag und entfernt ihn aus allen Annotationen
    /// (Roadmap #14: Relationen weg, Transaktionen bleiben).
    func delete(_ tag: Tag) async {
        do {
            try await dependencies.tagRepository.delete(id: tag.id)
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            actionError = String(localized: "Tag konnte nicht gelöscht werden.")
        }
    }

    func usageCount(for tagID: UUID) -> Int {
        usageCounts[tagID] ?? 0
    }
}
