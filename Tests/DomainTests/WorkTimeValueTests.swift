import Foundation
import Testing

@testable import FinanceTracker

/// Umrechnung Geld → Arbeitszeit (reine Rechenlogik; die Darstellung
/// „Lebenszeit“ wurde entfernt, die Logik bleibt für eine mögliche
/// künftige Kennzahl erhalten).
@Suite("WorkTimeValue")
struct WorkTimeValueTests {

    // MARK: - Basis

    @Test("Abgeschlossene Monate haben Vorrang vor dem laufenden")
    func averageWins() throws {
        // 40 Std/Woche → 173,33 Std/Monat. 3.000 € ⇒ ~17,31 €/Std.
        let basis = try #require(WorkTimeValue.basis(
            currentMonthIncome: 500,
            historyIncomes: [3000, 3000, 3000],
            weeklyHours: 40
        ))

        #expect(basis.source == .average(months: 3))
        #expect(basis.monthlyIncome == 3000)
        #expect(basis.hourlyValue > 17 && basis.hourlyValue < 17.5)
    }

    @Test("Monate ohne Einnahmen verwässern den Durchschnitt nicht")
    func zeroMonthsIgnored() throws {
        let basis = try #require(WorkTimeValue.basis(
            currentMonthIncome: 0,
            historyIncomes: [3000, 0, 3000, 0],
            weeklyHours: 40
        ))

        #expect(basis.source == .average(months: 2))
        #expect(basis.monthlyIncome == 3000)
    }

    @Test("Ohne Historie zählt der laufende Monat")
    func currentMonthFallback() throws {
        let basis = try #require(WorkTimeValue.basis(
            currentMonthIncome: 2000,
            historyIncomes: [],
            weeklyHours: 40
        ))

        #expect(basis.source == .currentMonth)
        #expect(basis.monthlyIncome == 2000)
    }

    @Test("Ohne jede Einnahme gibt es keine erfundene Basis")
    func noIncomeNoBasis() {
        #expect(WorkTimeValue.basis(
            currentMonthIncome: 0, historyIncomes: [0, 0], weeklyHours: 40
        ) == nil)
        #expect(WorkTimeValue.basis(
            currentMonthIncome: 3000, historyIncomes: [], weeklyHours: 0
        ) == nil)
    }

    // MARK: - Umrechnung

    @Test("Betrag wird zum Stundenwert in Zeit umgerechnet")
    func hoursForAmount() throws {
        let basis = try #require(WorkTimeValue.basis(
            currentMonthIncome: 0, historyIncomes: [1733.33], weeklyHours: 40
        ))
        // ~10 €/Std ⇒ 100 € ≈ 10 Std.
        let hours = basis.hours(for: 100)
        #expect(hours > 9.9 && hours < 10.1)
    }

    @Test("Vorzeichen spielt keine Rolle: Zeit ist immer positiv")
    func hoursIgnoreSign() throws {
        let basis = try #require(WorkTimeValue.basis(
            currentMonthIncome: 0, historyIncomes: [1733.33], weeklyHours: 40
        ))
        #expect(basis.hours(for: -100) == basis.hours(for: 100))
    }

    // MARK: - Formatierung

    @Test("Unter einer Stunde erscheinen Minuten")
    func formatMinutes() {
        #expect(WorkTimeValue.format(hours: 0.5, hoursPerDay: 8) == "30 Min")
        #expect(WorkTimeValue.format(hours: 0.01, hoursPerDay: 8) == "1 Min")
    }

    @Test("Unter einem Arbeitstag erscheinen Stunden")
    func formatHours() {
        #expect(WorkTimeValue.format(hours: 3, hoursPerDay: 8) == "3 Std")
        #expect(WorkTimeValue.format(hours: 7.6, hoursPerDay: 8) == "8 Std")
    }

    @Test("Ab einem Arbeitstag erscheinen Tage und Stunden")
    func formatDays() {
        #expect(WorkTimeValue.format(hours: 8, hoursPerDay: 8) == "1 T")
        #expect(WorkTimeValue.format(hours: 11, hoursPerDay: 8) == "1 T 3 Std")
        #expect(WorkTimeValue.format(hours: 40, hoursPerDay: 8) == "5 T")
    }

    @Test("Aufrundung erzeugt keinen überzähligen Stundenrest")
    func formatRoundingDoesNotOverflow() {
        // 15,9 Std ≈ 1 T 7,9 Std → gerundet 8 Std = voller Tag ⇒ „2 T".
        #expect(WorkTimeValue.format(hours: 15.9, hoursPerDay: 8) == "2 T")
    }

    @Test("Null bleibt null")
    func formatZero() {
        #expect(WorkTimeValue.format(hours: 0, hoursPerDay: 8) == "0 Std")
    }
}

/// Regressionsschutz für einen Fehler, den „glatte" Testwerte nicht zeigen:
/// Divisionen erzeugen Decimals mit bis zu 38 Nachkommastellen, und
/// `NSDecimalNumber.intValue` liefert dafür falsche Ergebnisse (es gab 0
/// statt 8 zurück). Die Werte hier stammen aus echten Demo-Daten.
@Suite("WorkTimeValuePrecision")
struct WorkTimeValuePrecisionTests {

    /// 2.850 € bei 40 Std/Woche ⇒ 16,4423… €/Std, bewusst ungerundet.
    private func realisticBasis() throws -> WorkTimeBasis {
        try #require(WorkTimeValue.basis(
            currentMonthIncome: 0,
            historyIncomes: [2850],
            weeklyHours: 40
        ))
    }

    @Test("Tageswerte mit langen Nachkommastellen werden korrekt gerundet")
    func longFractionDays() throws {
        let basis = try realisticBasis()

        // 1.068,89 € ≈ 65,0 Std ≈ 8 Arbeitstage + 1 Std.
        #expect(WorkTimeValue.format(
            hours: basis.hours(for: 1068.89), hoursPerDay: basis.hoursPerDay
        ) == "8 T 1 Std")

        // 985 € ≈ 59,9 Std ≈ 7 Arbeitstage + 4 Std.
        #expect(WorkTimeValue.format(
            hours: basis.hours(for: 985), hoursPerDay: basis.hoursPerDay
        ) == "7 T 4 Std")
    }

    @Test("Stunden- und Minutenwerte bleiben ebenfalls korrekt")
    func longFractionSubDay() throws {
        let basis = try realisticBasis()

        #expect(WorkTimeValue.format(
            hours: basis.hours(for: 43.69), hoursPerDay: basis.hoursPerDay
        ) == "3 Std")
        #expect(WorkTimeValue.format(
            hours: basis.hours(for: 6.30), hoursPerDay: basis.hoursPerDay
        ) == "23 Min")
    }

    @Test("Ergebnis wächst monoton mit dem Betrag")
    func monotonic() throws {
        let basis = try realisticBasis()
        let small = basis.hours(for: 100)
        let large = basis.hours(for: 1000)
        #expect(large > small)
        // Zehnfacher Betrag ⇒ zehnfache Zeit.
        #expect(large / small > 9.9 && large / small < 10.1)
    }
}
