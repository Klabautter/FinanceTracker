import Foundation

/// Command Palette (Roadmap #158–160): vereinheitlichte Suche über
/// Sektionen, Konten, Kategorien, Tags und Transaktionen.
@MainActor
@Observable
final class CommandPaletteModel {
    struct Entry: Identifiable, Hashable {
        enum Kind: Hashable {
            case section(AppSection)
            case reviewQueue
            case settings
            case account(Account)
            case category(Category)
            case tag(Tag)
            case transaction(Transaction)
        }

        let id: String
        let title: String
        let subtitle: String?
        let kind: Kind
    }

    private let dependencies: AppDependencies
    private let privacyState: PrivacyPresentationState

    private(set) var accounts: [Account] = []
    private(set) var categories: [Category] = []
    private(set) var tags: [Tag] = []

    init(dependencies: AppDependencies, privacyState: PrivacyPresentationState) {
        self.dependencies = dependencies
        self.privacyState = privacyState
    }

    func loadStaticEntries() async {
        do {
            async let accountsTask = dependencies.accountRepository.accounts()
            async let categoriesTask = dependencies.categoryRepository.categories()
            async let tagsTask = dependencies.tagRepository.tags()
            accounts = try await accountsTask
            categories = try await categoriesTask.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            tags = try await tagsTask.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            // Palette funktioniert auch ohne statische Einträge (Sektionen + Suche)
        }
    }

    func sectionEntries() -> [Entry] {
        AppSection.allCases.map { section in
            Entry(id: "section-\(section.rawValue)", title: section.title, subtitle: String(localized: "Bereich"), kind: .section(section))
        }
    }

    func reviewQueueEntry(openCount: Int?) -> Entry {
        Entry(
            id: "review-queue",
            title: String(localized: "Prüfen"),
            subtitle: openCount.map { String(localized: "\($0) offen") } ?? String(localized: "Prüfliste öffnen"),
            kind: .reviewQueue
        )
    }

    func settingsEntry() -> Entry {
        Entry(id: "settings", title: String(localized: "Einstellungen"), subtitle: String(localized: "Bereich"), kind: .settings)
    }

    func navigationEntries(reviewCount: Int?) -> [Entry] {
        sectionEntries() + [reviewQueueEntry(openCount: reviewCount), settingsEntry()]
    }

    func accountEntries(query: String) -> [Entry] {
        filter(accounts.map { account in
            Entry(
                id: "account-\(account.id.uuidString)",
                title: account.name,
                subtitle: account.type.displayName,
                kind: .account(account)
            )
        }, query: query)
    }

    func categoryEntries(query: String) -> [Entry] {
        filter(categories.map { category in
            Entry(
                id: "category-\(category.id.uuidString)",
                title: category.name,
                subtitle: category.parentID == nil ? String(localized: "Hauptkategorie") : String(localized: "Kategorie"),
                kind: .category(category)
            )
        }, query: query)
    }

    func tagEntries(query: String) -> [Entry] {
        filter(tags.map { tag in
            Entry(id: "tag-\(tag.id.uuidString)", title: tag.name, subtitle: String(localized: "Tag"), kind: .tag(tag))
        }, query: query)
    }

    /// Transaktions-Suche über DB-Pushdown (searchableText).
    func transactionEntries(query: String, limit: Int = 15) async -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        do {
            var txnQuery = TransactionQuery()
            txnQuery.searchText = needle.lowercased()
            txnQuery.limit = limit
            let page = try await dependencies.transactionRepository.transactionPage(
                matching: txnQuery,
                sort: .dateDescending,
                offset: 0,
                limit: limit
            )
            return page.transactions.map { txn in
                Entry(
                    id: "txn-\(txn.id.uuidString)",
                    title: txn.effectiveMerchantName,
                    subtitle: "\(AppDateFormatter.day(txn.displayDate)) · \(PrivacyAwareMoney.signed(txn.amount, privacy: privacyState))",
                    kind: .transaction(txn)
                )
            }
        } catch {
            return []
        }
    }

    private func filter(_ entries: [Entry], query: String) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }
}
