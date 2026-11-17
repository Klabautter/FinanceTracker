import Foundation

/// Command Palette (Roadmap #158–160): vereinheitlichte Suche über
/// Sektionen, Konten, Kategorien, Tags und Transaktionen.
@MainActor
@Observable
final class CommandPaletteModel {
    /// Nur, was dieses Model nutzt (Roadmap 7.4, `DependencyCapabilities`).
    typealias Dependencies = any HasAccountRepository & HasBaseCurrency & HasCategoryRepository & HasFxRateProvider & HasMerchantRepository & HasQuestionInterpreter & HasTagRepository & HasTransactionAnnotationRepository & HasTransactionRepository & HasTransactionSplitRepository

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

    /// Antwort auf eine Frage: die Zeile mit der Summe und die Buchungen,
    /// aus denen sie besteht (neueste zuerst, höchstens `shownLimit`).
    struct QuestionAnswer: Equatable {
        static let shownLimit = 8

        let text: String
        let entries: [Entry]
        /// Alle Buchungen hinter der Summe, auch die nicht gezeigten.
        let transactionCount: Int
        var hiddenCount: Int { max(0, transactionCount - entries.count) }
    }

    private let dependencies: Dependencies
    private let privacyState: PrivacyPresentationState

    private(set) var accounts: [Account] = []
    private(set) var categories: [Category] = []
    private(set) var tags: [Tag] = []

    init(dependencies: Dependencies, privacyState: PrivacyPresentationState) {
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

    /// Sieht die Eingabe wie eine Frage aus („Wie viel …", „…?")?
    static func looksLikeQuestion(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let starts = ["wie viel", "wieviel", "was habe", "was hab", "wie hoch", "how much", "what did"]
        return lower.hasSuffix("?") || starts.contains { lower.hasPrefix($0) }
    }

    /// Antwort auf eine Frage in normaler Sprache, ausgerechnet wie überall
    /// in der App (Cashflow-Regel, Anmerkungen, Splits, Umrechnung), mit den
    /// Buchungen hinter der Summe. `nil`, wenn die Eingabe keine Frage ist.
    func answer(question text: String, now: Date = Date()) async -> QuestionAnswer? {
        guard Self.looksLikeQuestion(text) else { return nil }
        do {
            let merchantNames = try await dependencies.merchantRepository.merchants().map(\.displayName)
            var question = FinanceQuestionParser.parse(text, categories: categories, merchantNames: merchantNames, now: now)
            // Nennt die Frage weder eine Kategorie noch einen Händler beim
            // Namen, ordnet das Sprachmodell des Geräts die Formulierung
            // einer vorhandenen Kategorie zu („Essen gehen" → Restaurants).
            if question.categoryIDs.isEmpty, question.merchantKey == nil,
               let interpreter = dependencies.questionInterpreter, interpreter.isAvailable,
               let name = await interpreter.categoryName(inQuestion: text, categoryNames: categories.map(\.name)),
               let category = categories.first(where: { $0.name == name }) {
                question = FinanceQuestionParser.assigning(category: category, to: question, categories: categories)
            }
            var query = TransactionQuery()
            query.dateInterval = question.period
            let raw = try await dependencies.transactionRepository.transactions(matching: query)
            let annotations = try await dependencies.transactionAnnotationRepository.annotations(transactionIDs: Set(raw.map(\.id)))
            let effective = EffectiveTransactionResolver().applying(annotations: annotations, to: raw)
            // Positionen nur, wenn nach einer Kategorie gefragt ist; ohne
            // Kategorie zählt jede Buchung als Ganzes.
            let splitLines = question.categoryIDs.isEmpty
                ? []
                : try await dependencies.transactionSplitRepository.splitLines(parentTransactionIDs: Set(raw.map(\.id)))
            let converter = await dependencies.fxRateProvider.converter()
            let result = FinanceQuestionParser.answer(
                question, transactions: effective, splitLines: splitLines,
                baseCurrency: dependencies.baseCurrency, converter: converter
            )
            let amount = PrivacyAwareMoney.signed(Money(amount: result.total, currency: result.currency), privacy: privacyState)
                .replacingOccurrences(of: "+", with: "")
            let subject = ([question.merchantName] + question.categoryNames.map(Optional.some)).compactMap { $0 }.joined(separator: ", ")
            let verb = question.measure == .income ? String(localized: "eingenommen") : String(localized: "ausgegeben")
            var line = subject.isEmpty
                ? String(localized: "\(question.periodLabel): \(amount) \(verb)")
                : String(localized: "\(subject) · \(question.periodLabel): \(amount) \(verb)")
            line += " " + String(localized: "(\(result.transactionIDs.count) Buchungen)")
            if result.excludedCount > 0 {
                line += " " + String(localized: "ohne \(result.excludedCount) Buchungen ohne Kurs")
            }

            let counted = Set(result.transactionIDs)
            let entries = effective
                .filter { counted.contains($0.id) }
                .sorted { $0.displayDate > $1.displayDate }
                .prefix(QuestionAnswer.shownLimit)
                .map { txn in
                    Entry(
                        id: "answer-txn-\(txn.id.uuidString)",
                        title: txn.effectiveMerchantName,
                        subtitle: "\(AppDateFormatter.day(txn.displayDate)) · \(PrivacyAwareMoney.signed(txn.amount, privacy: privacyState))",
                        kind: .transaction(txn)
                    )
                }
            return QuestionAnswer(text: line, entries: Array(entries), transactionCount: counted.count)
        } catch {
            return QuestionAnswer(
                text: String(localized: "Die Frage ließ sich gerade nicht beantworten."),
                entries: [],
                transactionCount: 0
            )
        }
    }

    private func filter(_ entries: [Entry], query: String) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }
}
