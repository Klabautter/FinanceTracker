import Foundation

enum PocketStatus: String, CaseIterable, Identifiable, Sendable {
    case active
    case upcoming
    case completed

    var id: Self { self }

    var title: String {
        switch self {
        case .active: String(localized: "Aktiv")
        case .upcoming: String(localized: "Zukünftig")
        case .completed: String(localized: "Abgeschlossen")
        }
    }

    var systemImage: String {
        switch self {
        case .active: "play.circle.fill"
        case .upcoming: "clock"
        case .completed: "checkmark.circle"
        }
    }

    static func status(
        startDate: Date,
        endDateExclusive: Date,
        now: Date
    ) -> PocketStatus {
        if now < startDate { return .upcoming }
        if now >= endDateExclusive { return .completed }
        return .active
    }
}

enum PocketEditorValidationError: Error, Equatable, Sendable {
    case emptyName
    case noActiveAccount
    case invalidDateRange
    case dateConversionFailed

    var message: String {
        switch self {
        case .emptyName: String(localized: "Bitte einen Namen eingeben.")
        case .noActiveAccount: String(localized: "Bitte mindestens ein aktives Konto oder eine aktive Karte auswählen.")
        case .invalidDateRange: String(localized: "Das Bis-Datum darf nicht vor dem Von-Datum liegen.")
        case .dateConversionFailed: String(localized: "Der gewählte Zeitraum konnte nicht verarbeitet werden.")
        }
    }
}

struct PocketEditorInput: Equatable, Sendable {
    var name: String
    var systemIconName: String
    var startDateInclusive: Date
    var endDateInclusive: Date
    var selectedAccountIDs: Set<UUID>

    init(
        name: String = "",
        systemIconName: String = "airplane",
        startDateInclusive: Date = Date(),
        endDateInclusive: Date? = nil,
        selectedAccountIDs: Set<UUID> = [],
        calendar: Calendar = .current
    ) {
        self.name = name
        self.systemIconName = systemIconName
        self.startDateInclusive = calendar.startOfDay(for: startDateInclusive)
        self.endDateInclusive = calendar.startOfDay(
            for: endDateInclusive
                ?? calendar.date(byAdding: .day, value: 7, to: startDateInclusive)
                ?? startDateInclusive
        )
        self.selectedAccountIDs = selectedAccountIDs
    }

    init(collection: TransactionCollection, calendar: Calendar = .current) {
        name = collection.name
        systemIconName = collection.systemIconName
        startDateInclusive = calendar.startOfDay(for: collection.startDate)
        endDateInclusive = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -1, to: collection.endDateExclusive)
                ?? collection.startDate
        )
        selectedAccountIDs = collection.accountIDs
    }

    func validationError(
        activeAccountIDs: Set<UUID>,
        calendar: Calendar = .current
    ) -> PocketEditorValidationError? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyName
        }
        if selectedAccountIDs.intersection(activeAccountIDs).isEmpty {
            return .noActiveAccount
        }
        if calendar.startOfDay(for: endDateInclusive) < calendar.startOfDay(for: startDateInclusive) {
            return .invalidDateRange
        }
        return nil
    }

    func collection(
        replacing existing: TransactionCollection?,
        activeAccountIDs: Set<UUID>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> TransactionCollection {
        if let error = validationError(activeAccountIDs: activeAccountIDs, calendar: calendar) {
            throw error
        }

        let start = calendar.startOfDay(for: startDateInclusive)
        let inclusiveEnd = calendar.startOfDay(for: endDateInclusive)
        guard let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: inclusiveEnd) else {
            throw PocketEditorValidationError.dateConversionFailed
        }

        return try TransactionCollection(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            systemIconName: systemIconName.isEmpty ? "tag" : systemIconName,
            startDate: start,
            endDateExclusive: exclusiveEnd,
            accountIDs: selectedAccountIDs.intersection(activeAccountIDs),
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
    }
}

struct PocketListItem: Identifiable, Hashable, Sendable {
    let snapshot: TransactionCollectionSnapshot
    let status: PocketStatus

    var id: UUID { snapshot.collection.id }
    var collection: TransactionCollection { snapshot.collection }
}

struct PocketTransactionRow: Identifiable, Hashable, Sendable {
    let transaction: Transaction
    let accountName: String
    let categoryName: String
    let overrideDecision: TransactionCollectionOverrideDecision?

    var id: UUID { transaction.id }
    var date: Date { transaction.displayDate }
    var merchant: String { transaction.effectiveMerchantName }
    var account: String { accountName }
    var category: String { categoryName }
    var amount: Decimal { transaction.amount.amount }
    var isManuallyAdded: Bool { overrideDecision == .include }
    var isExcluded: Bool { overrideDecision == .exclude }
}

enum PocketCandidateFilter {
    static func filter(
        _ rows: [PocketTransactionRow],
        searchText: String,
        accountID: UUID?
    ) -> [PocketTransactionRow] {
        let needle = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        return rows.filter { row in
            if let accountID, row.transaction.accountID != accountID { return false }
            guard !needle.isEmpty else { return true }
            let haystack = [row.merchant, row.account, row.category, row.transaction.rawDescription ?? ""]
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return haystack.localizedCaseInsensitiveContains(needle)
        }
    }
}

struct PocketCurrencySummaryPresentation: Identifiable, Hashable, Sendable {
    let currency: CurrencyCode
    let spending: Decimal
    let income: Decimal
    let netCashflow: Decimal

    var id: CurrencyCode { currency }

    static func rows(
        from summaries: [TransactionCollectionCurrencySummary]
    ) -> [PocketCurrencySummaryPresentation] {
        summaries.map {
            PocketCurrencySummaryPresentation(
                currency: $0.currency,
                spending: $0.spending,
                income: $0.income,
                netCashflow: $0.netCashflow
            )
        }
    }
}
