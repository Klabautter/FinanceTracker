import Foundation

struct AnalyticsSnapshot: Hashable, Sendable {
    let baseCurrency: CurrencyCode
    let totalIncome: Decimal
    let totalSpending: Decimal
    let transactionCount: Int
    /// Fremdwährungs-Transaktionen, die ohne Referenzkurs NICHT in den
    /// Summen enthalten sind (kein stiller Fallback).
    let excludedForeignTransactionCount: Int
    let excludedCurrencies: Set<CurrencyCode>
    /// Fremdwährungs-Transaktionen, die zum Referenzkurs in die
    /// Basiswährung umgerechnet wurden (Produkt-Entscheid 29.08.2026).
    let convertedForeignTransactionCount: Int
    let convertedCurrencies: Set<CurrencyCode>
    let pendingCount: Int
    let pendingAmount: Decimal
    let spendingByCategory: [CategoryTotal]
    let spendingByMerchant: [MerchantTotal]
    let dailySpending: [DailyTotal]
    /// Erhaltener Cashback im Zeitraum, je Währung getrennt
    /// (keine Addition über Währungen). Reine Zusatzinformation: er ist in
    /// KEINER Ausgaben-, Einnahmen- oder Saldo-Zahl verrechnet.
    var cashbackTotals: [CashbackTotal] = []

    var netCashflow: Decimal { totalIncome - totalSpending }
}

struct CashbackTotal: Identifiable, Hashable, Sendable {
    let currency: CurrencyCode
    let amount: Decimal

    var id: String { currency.rawValue }
}

struct CategoryTotal: Identifiable, Hashable, Sendable {
    let categoryID: UUID?
    let name: String
    let amount: Decimal
    /// Sammelposten für die kleineren Kategorien (nicht „Ohne Kategorie").
    var isRemainder = false

    var id: String { categoryID?.uuidString ?? "bucket:\(name)" }
}

struct MerchantTotal: Identifiable, Hashable, Sendable {
    let name: String
    let amount: Decimal

    var id: String { name }
}

struct DailyTotal: Identifiable, Hashable, Sendable {
    let day: Date
    let amount: Decimal

    var id: Date { day }
}

struct MonthlyCashflowPoint: Identifiable, Hashable, Sendable {
    let monthStart: Date
    let income: Decimal
    let spending: Decimal

    var id: Date { monthStart }
}

struct AnalyticsCalculator: Sendable {
    static var uncategorizedBucketName: String { String(localized: "Ohne Kategorie") }

    let baseCurrency: CurrencyCode
    private let converter: CurrencyConverter
    private let policy = CashflowPolicy.shared

    init(baseCurrency: CurrencyCode, converter: CurrencyConverter = CurrencyConverter()) {
        self.baseCurrency = baseCurrency
        self.converter = converter
    }

    /// Produkt-Entscheid 29.08.2026: Fremdwährungs-Transaktionen werden zum
    /// Referenzkurs in die Basiswährung umgerechnet und in allen Analytics-
    /// Aggregaten mitgezählt. Ohne Referenzkurs bleiben sie ausgeschlossen
    /// und werden über `excludedForeign*` transparent gemeldet.
    private struct BaseCurrencyConversion {
        let transactions: [Transaction]
        let ratesByTransactionID: [UUID: Decimal]
        let convertedCount: Int
        let convertedCurrencies: Set<CurrencyCode>
        let excludedCount: Int
        let excludedCurrencies: Set<CurrencyCode>
    }

    private func convertingToBase(_ transactions: [Transaction]) -> BaseCurrencyConversion {
        var converted: [Transaction] = []
        converted.reserveCapacity(transactions.count)
        var ratesByTransactionID: [UUID: Decimal] = [:]
        ratesByTransactionID.reserveCapacity(transactions.count)
        var convertedCurrencies = Set<CurrencyCode>()
        var convertedCount = 0
        var excludedCurrencies = Set<CurrencyCode>()
        var excludedCount = 0

        for var txn in transactions {
            if txn.amount.currency == baseCurrency {
                ratesByTransactionID[txn.id] = 1
                converted.append(txn)
                continue
            }
            guard let rate = converter.rate(from: txn.amount.currency, to: baseCurrency),
                  let baseAmount = converter.convert(txn.amount, to: baseCurrency) else {
                excludedCount += 1
                excludedCurrencies.insert(txn.amount.currency)
                continue
            }
            ratesByTransactionID[txn.id] = rate
            if txn.status != .reversed && txn.status != .cancelled
                && !policy.isExcluded(txn) {
                convertedCount += 1
                convertedCurrencies.insert(txn.amount.currency)
            }
            txn.amount = baseAmount
            converted.append(txn)
        }

        return BaseCurrencyConversion(
            transactions: converted,
            ratesByTransactionID: ratesByTransactionID,
            convertedCount: convertedCount,
            convertedCurrencies: convertedCurrencies,
            excludedCount: excludedCount,
            excludedCurrencies: excludedCurrencies
        )
    }

    /// Roadmap #71: Transaktionen mit Split-Lines werden für Kategorie-
    /// Breakdowns in ihre Split-Positionen zerlegt (Kategorie + anteiliger
    /// Betrag, Vorzeichen der Parent-Bewegung bleibt). Summen, Merchant und
    /// Monat bleiben durch die Aufteilung exakt erhalten. Splits erben
    /// Exclusion/Status/Transfer-Semantik vom Parent.
    private func expandingSplits(
        _ transactions: [Transaction],
        splitLines: [TransactionSplitLine],
        ratesByTransactionID: [UUID: Decimal]
    ) -> [Transaction] {
        guard !splitLines.isEmpty else { return transactions }
        let splitsByParent = Dictionary(grouping: splitLines, by: \.parentTransactionID)

        var result: [Transaction] = []
        result.reserveCapacity(transactions.count + splitLines.count)
        for txn in transactions {
            if let lines = splitsByParent[txn.id], !lines.isEmpty,
               let conversionRate = ratesByTransactionID[txn.id] {
                let sign: Decimal = txn.amount.amount < 0 ? -1 : 1
                for line in lines {
                    var copy = txn
                    copy.categoryID = line.categoryID
                    copy.amount = Money(
                        amount: sign * line.amount * conversionRate,
                        currency: txn.amount.currency
                    )
                    result.append(copy)
                }
            } else {
                result.append(txn)
            }
        }
        return result
    }

    /// Parent IDs represented by a category breakdown, with the same FX,
    /// status and split semantics as the overview.
    func transactionIDsContributing(
        to categoryIDs: Set<UUID?>,
        transactions: [Transaction],
        splitLines: [TransactionSplitLine] = []
    ) -> Set<UUID> {
        let conversion = convertingToBase(relevantTransactions(transactions))
        let breakdown = expandingSplits(
            conversion.transactions,
            splitLines: splitLines,
            ratesByTransactionID: conversion.ratesByTransactionID
        )
        return Set(breakdown.filter {
            policy.countsTowardBreakdowns($0) && categoryIDs.contains($0.categoryID)
        }.map(\.id))
    }

    func snapshot(
        transactions: [Transaction],
        categories: [Category],
        calendar: Calendar = .current,
        splitLines: [TransactionSplitLine] = [],
        categoryIDs: Set<UUID> = []
    ) -> AnalyticsSnapshot {
        let scoped = TransactionCategoryScope.projectingAmounts(
            transactions: transactions, splitLines: splitLines, categoryIDs: categoryIDs
        )
        let conversion = convertingToBase(relevantTransactions(scoped))
        let relevant = conversion.transactions
        let breakdownSource = expandingSplits(
            relevant,
            splitLines: splitLines,
            ratesByTransactionID: conversion.ratesByTransactionID
        ).filter {
            policy.countsTowardBreakdowns($0)
                && (categoryIDs.isEmpty || $0.categoryID.map { categoryIDs.contains($0) } == true)
        }

        var totalSpending = Decimal(0)
        var totalIncome = Decimal(0)
        var pendingCount = 0
        var pendingAmount = Decimal(0)

        for txn in relevant {
            if txn.status == .pending {
                pendingCount += 1
                if case .spending(let delta) = policy.contribution(for: txn), delta > 0 {
                    pendingAmount += delta
                }
            }

            switch policy.contribution(for: txn) {
            case .spending(let delta):
                totalSpending += delta
            case .income(let delta):
                totalIncome += delta
            case .neutral:
                break
            }
        }

        let expenses = breakdownSource

        let namesByID = Dictionary(
            categories.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        var byCategory: [UUID?: Decimal] = [:]
        for txn in expenses {
            byCategory[txn.categoryID, default: 0] += abs(txn.amount.amount)
        }
        let spendingByCategory = byCategory
            .map { key, value -> CategoryTotal in
                let name: String
                if let key, let resolved = namesByID[key] {
                    name = resolved
                } else if key == nil {
                    name = Self.uncategorizedBucketName
                } else {
                    name = String(localized: "Unbekannte Kategorie")
                }
                return CategoryTotal(categoryID: key, name: name, amount: value)
            }
            .sorted { $0.amount > $1.amount }

        var byMerchant: [String: Decimal] = [:]
        for txn in expenses {
            byMerchant[merchantKey(for: txn), default: 0] += abs(txn.amount.amount)
        }
        let spendingByMerchant = byMerchant
            .map { MerchantTotal(name: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }

        var byDay: [Date: Decimal] = [:]
        for txn in expenses {
            let day = calendar.startOfDay(for: txn.displayDate)
            byDay[day, default: 0] += abs(txn.amount.amount)
        }
        let dailySpending = byDay
            .map { DailyTotal(day: $0.key, amount: $0.value) }
            .sorted { $0.day < $1.day }

        return AnalyticsSnapshot(
            baseCurrency: baseCurrency,
            totalIncome: totalIncome,
            totalSpending: totalSpending,
            transactionCount: relevant.count,
            excludedForeignTransactionCount: conversion.excludedCount,
            excludedCurrencies: conversion.excludedCurrencies,
            convertedForeignTransactionCount: conversion.convertedCount,
            convertedCurrencies: conversion.convertedCurrencies,
            pendingCount: pendingCount,
            pendingAmount: pendingAmount,
            spendingByCategory: spendingByCategory,
            spendingByMerchant: spendingByMerchant,
            dailySpending: dailySpending,
            cashbackTotals: cashbackTotals(in: relevantTransactions(scoped))
        )
    }

    /// Summiert den an den Buchungen gespeicherten Cashback je Währung.
    /// Basis sind die Buchungen VOR der Währungsumrechnung: Cashback einer
    /// nicht umrechenbaren Fremdwährungsbuchung bleibt sichtbar.
    func cashbackTotals(in transactions: [Transaction]) -> [CashbackTotal] {
        var sums: [CurrencyCode: Decimal] = [:]
        for transaction in transactions {
            guard let amount = transaction.cashbackAmount, amount > 0 else { continue }
            sums[transaction.cashbackCurrency ?? transaction.amount.currency, default: 0] += amount
        }
        return sums
            .map { CashbackTotal(currency: $0.key, amount: $0.value) }
            .sorted { lhs, rhs in
                if (lhs.currency == baseCurrency) != (rhs.currency == baseCurrency) {
                    return lhs.currency == baseCurrency
                }
                return lhs.currency.rawValue < rhs.currency.rawValue
            }
    }

    func monthlyPoints(
        transactions: [Transaction],
        monthsBack: Int,
        calendar: Calendar = .current,
        splitLines: [TransactionSplitLine] = [],
        referenceDate: Date = Date(),
        categoryIDs: Set<UUID> = []
    ) -> [MonthlyCashflowPoint] {
        let scoped = TransactionCategoryScope.projectingAmounts(
            transactions: transactions, splitLines: splitLines, categoryIDs: categoryIDs
        )
        let conversion = convertingToBase(relevantTransactions(scoped))
        // Monthly totals use parents; splitting is only needed for category attribution.
        let relevant = conversion.transactions

        guard monthsBack > 0 else { return [] }
        let today = calendar.startOfDay(for: referenceDate)

        var monthStarts: [Date] = []
        for offset in stride(from: monthsBack - 1, through: 0, by: -1) {
            if let date = calendar.date(byAdding: .month, value: -offset, to: today),
               let start = monthStart(of: date, calendar: calendar) {
                monthStarts.append(start)
            }
        }

        var incomeByMonth: [Date: Decimal] = [:]
        var spendingByMonth: [Date: Decimal] = [:]
        for start in monthStarts {
            incomeByMonth[start] = 0
            spendingByMonth[start] = 0
        }

        for txn in relevant {
            guard let start = monthStart(of: txn.displayDate, calendar: calendar),
                  incomeByMonth[start] != nil else { continue }
            switch policy.contribution(for: txn) {
            case .spending(let delta):
                spendingByMonth[start]? += delta
            case .income(let delta):
                incomeByMonth[start]? += delta
            case .neutral:
                break
            }
        }

        return monthStarts.compactMap { start in
            guard let income = incomeByMonth[start], let spending = spendingByMonth[start] else {
                return nil
            }
            return MonthlyCashflowPoint(monthStart: start, income: income, spending: spending)
        }
    }

    private func relevantTransactions(_ transactions: [Transaction]) -> [Transaction] {
        transactions.filter { txn in
            txn.status != .reversed
                && txn.status != .cancelled
                && !policy.isExcluded(txn)
        }
    }

    private func merchantKey(for txn: Transaction) -> String {
        let raw = txn.merchantDisplayName ?? txn.rawMerchantName ?? txn.rawDescription ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Unbekannt") : trimmed
    }

    private func monthStart(of date: Date, calendar: Calendar) -> Date? {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))
    }
}
