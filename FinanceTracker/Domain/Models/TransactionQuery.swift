import Foundation

extension DateInterval {
    /// Prüft ein fachliches Zeitfenster nach der einheitlichen Semantik
    /// `[start, end)`: Start inklusive, Ende exklusiv.
    func containsHalfOpen(_ date: Date) -> Bool {
        start <= date && date < end
    }
}

enum TransactionSortOrder: String, Codable, Sendable, Hashable, CaseIterable {
    case dateDescending
    case dateAscending
    case amountDescending
    case amountAscending
    case merchantAscending
    case merchantDescending

    var displayName: String {
        switch self {
        case .dateDescending: String(localized: "Neueste zuerst")
        case .dateAscending: String(localized: "Älteste zuerst")
        case .amountDescending: String(localized: "Höchster Betrag")
        case .amountAscending: String(localized: "Niedrigster Betrag")
        case .merchantAscending: String(localized: "Händler A–Z")
        case .merchantDescending: String(localized: "Händler Z–A")
        }
    }
}

/// WP9 (§71): Tag-Match-Semantik der Query, ANY (eines der Tags) oder
/// ALL (alle Tags, global korrekt via ID-Intersect-Pushdown).
enum TagMatchMode: String, Sendable, Hashable, Codable {
    case any
    case all
}

struct TransactionQuery: Sendable, Hashable {
    var searchText: String = ""
    var dateInterval: DateInterval?
    var accountIDs: Set<UUID> = []
    var categoryIDs: Set<UUID> = []
    var statuses: Set<TransactionStatus> = []
    /// WP19: Tag-Filter (DB-Pushdown über Join-Rows).
    var tagIDs: Set<UUID> = []
    /// WP9 (§71): Match-Modus für tagIDs (any/all), kein Best-Effort.
    var tagMatchMode: TagMatchMode = .any
    var sources: Set<TransactionSource> = []
    var sort: TransactionSortOrder = .dateDescending
    var limit: Int?

    func matches(_ transaction: Transaction) -> Bool {
        if let interval = dateInterval {
            guard interval.containsHalfOpen(transaction.displayDate) else { return false }
        }

        if !accountIDs.isEmpty, !accountIDs.contains(transaction.accountID) {
            return false
        }

        if !categoryIDs.isEmpty {
            guard let categoryID = transaction.categoryID, categoryIDs.contains(categoryID) else {
                return false
            }
        }

        if !statuses.isEmpty, !statuses.contains(transaction.status) {
            return false
        }

        if !sources.isEmpty, !sources.contains(transaction.source) {
            return false
        }

        // WP9 (§71): Tag-Filter im matches()-Korrektheitsnetz, Modus-aware.
        if !tagIDs.isEmpty {
            let txnTags = Set(transaction.tagIDs ?? [])
            switch tagMatchMode {
            case .any:
                if txnTags.isDisjoint(with: tagIDs) { return false }
            case .all:
                if !tagIDs.isSubset(of: txnTags) { return false }
            }
        }

        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            let haystacks = [
                transaction.effectiveMerchantName,
                transaction.rawMerchantName ?? "",
                transaction.rawDescription ?? ""
            ]
            if !haystacks.contains(where: { $0.lowercased().contains(needle) }) {
                return false
            }
        }

        return true
    }

    func applying(to transactions: [Transaction]) -> [Transaction] {
        refining(transactions.filter(matches))
    }

    func refining(_ transactions: [Transaction]) -> [Transaction] {
        var result = transactions

        if !categoryIDs.isEmpty {
            result = result.filter { txn in
                guard let categoryID = txn.categoryID else { return false }
                return categoryIDs.contains(categoryID)
            }
        }

        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            result = result.filter { txn in
                let candidates = [
                    txn.effectiveMerchantName,
                    txn.rawMerchantName ?? "",
                    txn.rawDescription ?? ""
                ]
                return candidates.contains { $0.lowercased().contains(needle) }
            }
        }

        switch sort {
        case .dateDescending:
            result.sort { $0.displayDate > $1.displayDate }
        case .dateAscending:
            result.sort { $0.displayDate < $1.displayDate }
        case .amountDescending:
            result.sort { $0.amount.amount > $1.amount.amount }
        case .amountAscending:
            result.sort { $0.amount.amount < $1.amount.amount }
        case .merchantAscending:
            result.sort { $0.effectiveMerchantName.localizedCaseInsensitiveCompare($1.effectiveMerchantName) == .orderedAscending }
        case .merchantDescending:
            result.sort { $0.effectiveMerchantName.localizedCaseInsensitiveCompare($1.effectiveMerchantName) == .orderedDescending }
        }
        if let limit {
            result = Array(result.prefix(limit))
        }
        return result
    }
}
