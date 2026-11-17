import Foundation

/// Budget 2.0 (Roadmap #96–100).
struct Budget: Identifiable, Hashable, Codable, Sendable {
    let id: UUID

    var name: String
    var systemIconName: String
    var amount: Decimal
    var currency: CurrencyCode

    var periodPolicy: BudgetPeriodPolicy
    /// Zugeordnete Kategorien (Leaf-only, Roadmap #43).
    var categoryIDs: Set<UUID>
    /// Optional: Tag- und Konto-Scopes (V1 noch ohne Wirkung, Architektur vorbereitet).
    var tagIDs: Set<UUID>
    var accountIDs: Set<UUID>

    var rolloverPolicy: BudgetRolloverPolicy
    var includeInForecast: Bool
    var enabled: Bool
    /// Beginn der fachlichen Budgethistorie. `nil` ist nur für ältere
    /// Archive ohne diesen Wert zulässig.
    var createdAt: Date?

    /// P2 Sparziel (Sinking-Fund-Ziel): optionaler Zielbetrag + Zieldatum.
    /// Kein Parallelmodell (#11/#30): accumulate-Budgets + RecurringCommitment
    /// bleiben die Mechanik; diese Felder sind nur die Zielmarke. Währung ist
    /// immer `currency` des Budgets (#19/#35: keine Währungs-Mischung).
    /// `nil` = kein Sparziel.
    var targetAmount: Decimal?
    var targetDate: Date?

    var isSalaryCycle: Bool {
        if case .salaryCycle = periodPolicy { return true }
        return false
    }

    init(
        id: UUID = UUID(),
        name: String,
        systemIconName: String = "chart.pie",
        amount: Decimal,
        currency: CurrencyCode = .eur,
        periodPolicy: BudgetPeriodPolicy = .calendarMonth(startDay: 1),
        categoryIDs: Set<UUID> = [],
        tagIDs: Set<UUID> = [],
        accountIDs: Set<UUID> = [],
        rolloverPolicy: BudgetRolloverPolicy = .reset,
        includeInForecast: Bool = true,
        enabled: Bool = true,
        targetAmount: Decimal? = nil,
        targetDate: Date? = nil,
        createdAt: Date? = Date()
    ) {
        self.id = id
        self.name = name
        self.systemIconName = systemIconName
        self.amount = amount
        self.currency = currency
        self.periodPolicy = periodPolicy
        self.categoryIDs = categoryIDs
        self.tagIDs = tagIDs
        self.accountIDs = accountIDs
        self.rolloverPolicy = rolloverPolicy
        self.includeInForecast = includeInForecast
        self.enabled = enabled
        self.createdAt = createdAt
        self.targetAmount = targetAmount
        self.targetDate = targetDate
    }

    /// Sparziel gesetzt (Zielbetrag > 0 erforderlich; Datum optional).
    var hasSavingsGoal: Bool {
        if let targetAmount, targetAmount > 0 { return true }
        return false
    }
}

/// Budget-Zeitraum (#97). Salary-Cycle ist vorbereitet und wird mit
/// Recurring Income (#117) aktiv.
enum BudgetPeriodPolicy: Hashable, Codable, Sendable {
    case calendarMonth(startDay: Int)
    case salaryCycle(recurringIncomeID: UUID)
}

/// Rollover (#98): reset = monatliches Limit; accumulate = Rücklage, Rest
/// rollt in die nächste Periode (Sinking Fund).
enum BudgetRolloverPolicy: String, Codable, Sendable {
    case reset
    case accumulate
}

/// WP4 (§28/§32): Reine Merge-Logik des Budget-Formulars, testbar ohne
/// SwiftUI. Display-Formatting und Edit-Input sind getrennt; der Betrag
/// kommt als typed Decimal.
struct BudgetFormEdit: Sendable {
    var name: String
    var systemIconName: String
    var amount: Decimal
    var categoryIDs: Set<UUID>
    var rolloverAccumulate: Bool
    var periodPolicy: BudgetPeriodPolicy
    /// P2 Sparziel (optional, gleiche Währung wie das Budget).
    var targetAmount: Decimal?
    var targetDate: Date?

    /// §32 Option B: Currency eines existierenden Budgets bleibt NICHT still
    /// auf Base Currency überschrieben (keine stille Mutation). Nur neue
    /// Budgets erhalten die Base Currency.
    func applied(to existing: Budget?, baseCurrency: CurrencyCode) -> Budget {
        var budget = existing ?? Budget(
            name: name,
            amount: amount,
            currency: baseCurrency,
            categoryIDs: categoryIDs,
            rolloverPolicy: rolloverAccumulate ? .accumulate : .reset
        )
        budget.periodPolicy = periodPolicy
        budget.name = name
        budget.systemIconName = systemIconName
        budget.amount = amount
        if existing == nil {
            budget.currency = baseCurrency
        }
        budget.categoryIDs = categoryIDs
        budget.rolloverPolicy = rolloverAccumulate ? .accumulate : .reset
        // P2 Sparziel: nur positive Zielbeträge übernehmen; ungültige
        // Eingaben werden als "kein Ziel" gespeichert (kein stiller Fallback
        // auf 0: 0 ist kein gültiges Ziel).
        if let targetAmount, targetAmount > 0 {
            budget.targetAmount = targetAmount
            budget.targetDate = targetDate
        } else {
            budget.targetAmount = nil
            budget.targetDate = nil
        }
        return budget
    }
}

struct BudgetProgress: Identifiable, Hashable, Sendable {
    let budget: Budget
    let spent: Decimal
    let currency: CurrencyCode
    /// WP6 (§48): Die vom BudgetPeriodResolver aufgelöste Periode. Budget
    /// Detail und Projektion verwenden EXAKT dieses Intervall: Overview
    /// und Detail können nicht divergieren (§46).
    let period: DateInterval
    /// Rollover-Rest aus der Vorperiode (nur bei .accumulate > 0).
    var carriedOver: Decimal = 0
    /// Roadmap #99: Historischer Betrag (überschreibt budget.amount).
    var limitOverride: Decimal?
    /// Währungen ohne Referenzkurs, deren Transaktionen auf dieses Budget
    /// gezählt hätten. Bewusst NICHT in `spent` enthalten: die UI muss sie
    /// ausweisen (kein stiller Fallback).
    var excludedCurrencies: Set<CurrencyCode> = []

    var limit: Decimal { limitOverride ?? budget.amount }
    var effectiveLimit: Decimal { max(0, limit + carriedOver) }

    var fraction: Double {
        guard effectiveLimit > 0 else { return 0 }
        return max(0, min(1, NSDecimalNumber(decimal: spent / effectiveLimit).doubleValue))
    }

    var isOverBudget: Bool { spent > effectiveLimit }
    var remaining: Decimal { max(0, effectiveLimit - spent) }

    var id: UUID { budget.id }
}
