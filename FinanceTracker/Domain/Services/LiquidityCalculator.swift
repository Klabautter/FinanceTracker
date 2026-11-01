import Foundation

/// Gesamtstand der liquiden Mittel über alle aktiven Konten mit bekanntem
/// Stand, in der Basiswährung. Fremdwährungen nur über einen expliziten
/// Kurs (#19, #35); Konten ohne Stand oder ohne Kurs werden nicht still
/// mitgezählt, sondern gemeldet. Depotbestände sind nicht enthalten.
struct LiquidityOverview: Sendable, Hashable {
    struct Share: Identifiable, Sendable, Hashable {
        let summary: AccountSummary
        /// Stand in Kontowährung.
        let balance: Money
        /// Stand in Basiswährung.
        let converted: Money
        let isConverted: Bool
        /// Anteil am Guthaben (nur positive Stände, 0…1, nur Anzeige).
        let fraction: Double

        var id: UUID { summary.id }
    }

    let total: Money
    /// Konten mit Stand, größter Betrag zuerst.
    let shares: [Share]
    /// Aktive Konten ohne bekannten Stand.
    let withoutBalance: [AccountSummary]
    /// Konten mit Stand, aber ohne Kurs in die Basiswährung.
    let unconvertible: [AccountSummary]

    var usesConversion: Bool { shares.contains(where: \.isConverted) }
    /// Ältester gemeldeter Stand, der in die Summe eingeht.
    var oldestReportedAt: Date? { shares.compactMap(\.summary.balanceReportedAt).min() }
}

/// Wie lange der Gesamtstand bei den bisherigen Ausgaben reicht.
struct LiquidityRunway: Sendable, Hashable {
    /// Ausgaben eines typischen Monats: Median der Monate, damit ein
    /// einzelner Ausreißer (z. B. ein Autokauf) die Reichweite nicht
    /// verzerrt. Unter drei Monaten der Mittelwert.
    let typicalMonthlySpending: Money
    let typicalMonthlyNet: Money
    /// Anzahl voller Monate, die eingeflossen sind.
    let monthCount: Int
    /// Monate, die der Gesamtstand bei den Durchschnittsausgaben reicht;
    /// `nil` ohne Ausgaben.
    let months: Decimal?
}

struct LiquidityCalculator: Sendable {
    static let maximumRunwayMonths = 6

    let baseCurrency: CurrencyCode
    let converter: CurrencyConverter

    func overview(of summaries: [AccountSummary]) -> LiquidityOverview {
        var converted: [(AccountSummary, Money, Money)] = []
        var withoutBalance: [AccountSummary] = []
        var unconvertible: [AccountSummary] = []
        for summary in summaries where summary.account.isActive {
            guard let balance = summary.balance else {
                withoutBalance.append(summary)
                continue
            }
            guard let base = converter.convert(balance, to: baseCurrency) else {
                unconvertible.append(summary)
                continue
            }
            converted.append((summary, balance, base))
        }

        let total = converted.reduce(Decimal(0)) { $0 + $1.2.amount }
        let positive = converted.reduce(Decimal(0)) { $0 + max(0, $1.2.amount) }
        let shares = converted
            .map { summary, balance, base in
                LiquidityOverview.Share(
                    summary: summary,
                    balance: balance,
                    converted: base,
                    isConverted: balance.currency != baseCurrency,
                    fraction: positive > 0
                        ? NSDecimalNumber(decimal: max(0, base.amount) / positive).doubleValue
                        : 0
                )
            }
            .sorted { $0.converted.amount > $1.converted.amount }

        return LiquidityOverview(
            total: Money(amount: total, currency: baseCurrency),
            shares: shares,
            withoutBalance: withoutBalance,
            unconvertible: unconvertible
        )
    }

    /// Typischer Monat aus den letzten vollen Monaten mit Buchungen (höchstens
    /// `maximumRunwayMonths`), der laufende Monat zählt nicht. `points` sind
    /// die Monatswerte der Übersicht: Umbuchungen zählen dort nicht als
    /// Ausgabe, Sparpläne und Käufe schon (#28).
    func runway(
        total: Money,
        monthlyPoints: [MonthlyCashflowPoint],
        now: Date,
        calendar: Calendar = .current
    ) -> LiquidityRunway? {
        guard let currentMonth = calendar.dateInterval(of: .month, for: now)?.start else { return nil }
        let full = monthlyPoints
            .filter { $0.monthStart < currentMonth && ($0.spending != 0 || $0.income != 0) }
            .sorted { $0.monthStart > $1.monthStart }
            .prefix(Self.maximumRunwayMonths)
        guard !full.isEmpty else { return nil }
        let spending = Self.typical(full.map(\.spending))
        let net = Self.typical(full.map { $0.income - $0.spending })
        return LiquidityRunway(
            typicalMonthlySpending: Money(amount: spending, currency: baseCurrency),
            typicalMonthlyNet: Money(amount: net, currency: baseCurrency),
            monthCount: full.count,
            months: spending > 0 ? max(0, total.amount) / spending : nil
        )
    }

    /// Median ab drei Werten (robust gegen einen Ausreißer), sonst Mittelwert.
    static func typical(_ values: [Decimal]) -> Decimal {
        guard !values.isEmpty else { return 0 }
        guard values.count >= 3 else {
            return values.reduce(Decimal(0), +) / Decimal(values.count)
        }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
