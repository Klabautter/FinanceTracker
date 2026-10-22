import Foundation

/// Umrechnung von Geld in Arbeitszeit.
///
/// Idee der Darstellung „Lebenszeit": Nicht „was kostet das?", sondern
/// „wie lange musst du dafür arbeiten?". Der Bezugsrahmen wechselt von
/// Euro zu Zeit: dieselben Daten, eine andere Frage.
///
/// Die Rechnung ist bewusst schlicht und offengelegt (die Darstellung zeigt
/// ihre Basis an): Stundenwert = monatliche Einnahmen ÷ Arbeitsstunden im
/// Monat. Es ist eine Veranschaulichung, keine Beratung, deshalb enthält
/// dieser Typ keine Empfehlungen, nur Umrechnungen.
struct WorkTimeBasis: Equatable, Sendable {
    /// Wert einer Arbeitsstunde in Basiswährung.
    let hourlyValue: Decimal
    /// Zugrunde gelegte monatliche Einnahmen.
    let monthlyIncome: Decimal
    let weeklyHours: Int
    /// Woher die Einnahmen stammen; die Darstellung weist das aus, damit
    /// die Zahl nachvollziehbar bleibt.
    let source: Source

    enum Source: Equatable, Sendable {
        case currentMonth
        /// Durchschnitt über `months` Monate mit Einnahmen.
        case average(months: Int)
    }

    /// Stunden eines regulären Arbeitstages (Fünftagewoche).
    var hoursPerDay: Decimal { Decimal(weeklyHours) / 5 }

    func hours(for amount: Decimal) -> Decimal {
        guard hourlyValue > 0 else { return 0 }
        return abs(amount) / hourlyValue
    }
}

enum WorkTimeValue {
    /// Wochenstunden, die ohne eigene Angabe angenommen werden.
    static let defaultWeeklyHours = 40
    /// Wochen pro Monat (52 ÷ 12), als exakter Bruch, nicht als Float.
    private static let weeksPerMonth = Decimal(52) / Decimal(12)

    /// Ermittelt die Rechenbasis.
    ///
    /// Der laufende Monat ist meist unvollständig (Gehalt kommt am Ende),
    /// deshalb hat der Durchschnitt abgeschlossener Monate Vorrang. Ohne
    /// jede Einnahme gibt es keine Basis, dann `nil` statt einer erfundenen
    /// Zahl.
    static func basis(
        currentMonthIncome: Decimal,
        historyIncomes: [Decimal],
        weeklyHours: Int
    ) -> WorkTimeBasis? {
        guard weeklyHours > 0 else { return nil }

        let earning = historyIncomes.filter { $0 > 0 }
        let income: Decimal
        let source: WorkTimeBasis.Source
        if !earning.isEmpty {
            income = earning.reduce(into: Decimal(0)) { $0 += $1 } / Decimal(earning.count)
            source = .average(months: earning.count)
        } else if currentMonthIncome > 0 {
            income = currentMonthIncome
            source = .currentMonth
        } else {
            return nil
        }

        let monthlyHours = Decimal(weeklyHours) * weeksPerMonth
        guard monthlyHours > 0 else { return nil }

        return WorkTimeBasis(
            hourlyValue: income / monthlyHours,
            monthlyIncome: income,
            weeklyHours: weeklyHours,
            source: source
        )
    }

    /// Formatiert eine Stundenzahl als Arbeitszeit: Minuten unter einer
    /// Stunde, Stunden unter einem Arbeitstag, darüber Tage plus Stunden.
    static func format(hours: Decimal, hoursPerDay: Decimal) -> String {
        guard hours > 0 else { return String(localized: "0 Std") }

        if hours < 1 {
            let minutes = max(1, rounded(hours * 60))
            return String(localized: "\(minutes) Min")
        }
        guard hoursPerDay > 0, hours >= hoursPerDay else {
            return String(localized: "\(rounded(hours)) Std")
        }

        let days = floored(hours / hoursPerDay)
        let remainder = hours - Decimal(days) * hoursPerDay
        let remainingHours = rounded(remainder)

        // Aufrundung darf keinen vollen Tag als „7 T 8 Std" zeigen.
        if Decimal(remainingHours) >= hoursPerDay {
            return String(localized: "\(days + 1) T")
        }
        return remainingHours > 0
            ? String(localized: "\(days) T \(remainingHours) Std")
            : String(localized: "\(days) T")
    }

    /// Divisionen liefern hier Decimals mit bis zu 38 Nachkommastellen.
    /// `NSDecimalNumber.intValue` ist für solche Werte NICHT verlässlich:
    /// es lieferte für 8,126… glatt 0. Deshalb wird immer zuerst über
    /// `NSDecimalRound` auf eine ganze Zahl gebracht und erst dann gelesen.
    private static func rounded(_ value: Decimal) -> Int {
        integer(value, mode: .plain)
    }

    private static func floored(_ value: Decimal) -> Int {
        integer(value, mode: .down)
    }

    private static func integer(_ value: Decimal, mode: NSDecimalNumber.RoundingMode) -> Int {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 0, mode)
        return NSDecimalNumber(decimal: result).intValue
    }
}
