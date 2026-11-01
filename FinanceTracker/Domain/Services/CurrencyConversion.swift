import Foundation

/// Explizite Währungskonvertierung: Fremdwährungen fließen
/// nur über einen deklarierten Kurs in Basiswährungs-Summen, nie still.
///
/// Produkt-Entscheid (29.08.2026): Fremdwährungs-Transaktionen werden zum
/// Referenzkurs in die Basiswährung umgerechnet und in Analytics/Cashflow
/// mitgezählt. Kurse sind kuratierte statische Richtkurse (1 Einheit → EUR);
/// die UI weist umgerechnete Summen immer als „Referenzkurs“ aus. Währungen
/// ohne Referenzkurs bleiben ausgeschlossen und werden gemeldet, keine
/// stillen Fallback-Werte.
struct CurrencyConverter: Sendable, Equatable {
    /// Calendar date represented by the bundled static reference rates.
    static let referenceEURQuoteDate = Self.referenceDate("2026-08-29")

    private static func referenceDate(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else {
            preconditionFailure("Ungültiges Referenzkursdatum")
        }
        return date
    }

    /// Parst ein Kurs-Literal exakt (keine Float-Umwege: `Decimal(0.92)`
    /// würde die binäre Double-Darstellung einbetten).
    private static func decimal(_ literal: String) -> Decimal {
        guard let value = Decimal(string: literal) else {
            preconditionFailure("Ungültiger Referenzkurs-Literal: \(literal)")
        }
        return value
    }

    /// Kuratierte Richtkurse: 1 Einheit der Währung in EUR (Stand 29.08.2026).
    static let referenceEURRates: [CurrencyCode: Decimal] = [
        CurrencyCode("USD"): decimal("0.92"),
        CurrencyCode("GBP"): decimal("1.17"),
        CurrencyCode("CHF"): decimal("1.06"),
        CurrencyCode("JPY"): decimal("0.0062"),
        CurrencyCode("CAD"): decimal("0.67"),
        CurrencyCode("AUD"): decimal("0.61"),
        CurrencyCode("NZD"): decimal("0.56"),
        CurrencyCode("SEK"): decimal("0.088"),
        CurrencyCode("NOK"): decimal("0.085"),
        CurrencyCode("DKK"): decimal("0.134"),
        CurrencyCode("PLN"): decimal("0.23"),
        CurrencyCode("CZK"): decimal("0.040"),
        CurrencyCode("HUF"): decimal("0.0025"),
        CurrencyCode("RON"): decimal("0.20"),
        CurrencyCode("TRY"): decimal("0.022"),
        CurrencyCode("CNY"): decimal("0.13"),
        CurrencyCode("INR"): decimal("0.011"),
        CurrencyCode("BRL"): decimal("0.17"),
        CurrencyCode("ZAR"): decimal("0.051"),
        CurrencyCode("SGD"): decimal("0.69"),
        CurrencyCode("HKD"): decimal("0.118")
    ]

    private let eurPerUnit: [CurrencyCode: Decimal]
    /// Tageskurse für Buchungen: Ausgaben und Einnahmen zählen zum Kurs
    /// ihres Tages, nicht zum heutigen. Ohne Tageskurs gilt `eurPerUnit`.
    private let daily: DailyFXRates?

    init(eurPerUnit: [CurrencyCode: Decimal] = CurrencyConverter.referenceEURRates, daily: DailyFXRates? = nil) {
        self.eurPerUnit = eurPerUnit
        self.daily = daily
    }

    /// Multiplikator von `source` nach `target`. `nil` = kein Kurs vorhanden:
    /// der Aufrufer muss den Wert dann explizit ausschließen und melden.
    func rate(from source: CurrencyCode, to target: CurrencyCode) -> Decimal? {
        if source == target { return 1 }
        guard let sourceToEUR = eurRate(of: source),
              let targetToEUR = eurRate(of: target) else { return nil }
        return sourceToEUR / targetToEUR
    }

    /// Konvertiert einen Betrag in die Zielwährung. Gleiche Währung wird
    /// unverändert durchgereicht.
    func convert(_ money: Money, to target: CurrencyCode) -> Money? {
        guard let rate = rate(from: money.currency, to: target) else { return nil }
        return Money(amount: money.amount * rate, currency: target)
    }

    /// Kurs am Tag `date` (letzter veröffentlichter Kurs bis dahin, z. B.
    /// Freitag für einen Sonntag); ohne Tageskurs der aktuelle Kurs.
    func rate(from source: CurrencyCode, to target: CurrencyCode, on date: Date) -> Decimal? {
        if source == target { return 1 }
        if let rates = daily?.rates(on: date) {
            let sourceToEUR = source == .eur ? 1 : rates[source]
            let targetToEUR = target == .eur ? 1 : rates[target]
            if let sourceToEUR, let targetToEUR { return sourceToEUR / targetToEUR }
        }
        return rate(from: source, to: target)
    }

    /// Kurs für eine Buchung in die Zielwährung. Nennt die Buchung ihren
    /// Gegenwert in der Zielwährung (z. B. „Original: EUR 4,00" auf einer
    /// Dollar-Karte), ist das der exakte Kurs; sonst der Kurs ihres Tages.
    func rate(for transaction: Transaction, to target: CurrencyCode) -> Decimal? {
        let amount = transaction.amount
        if amount.currency == target { return 1 }
        if transaction.originalCurrency == target,
           let original = transaction.originalAmount, original != 0, amount.amount != 0 {
            return abs(original) / abs(amount.amount)
        }
        return rate(from: amount.currency, to: target, on: transaction.displayDate)
    }

    func convert(_ transaction: Transaction, to target: CurrencyCode) -> Money? {
        // Exakter Gegenwert ohne Rundung über den Kurs.
        if transaction.amount.currency != target, transaction.originalCurrency == target,
           let original = transaction.originalAmount, original != 0, transaction.amount.amount != 0 {
            return Money(amount: transaction.amount.amount < 0 ? -abs(original) : abs(original), currency: target)
        }
        guard let rate = rate(for: transaction, to: target) else { return nil }
        return Money(amount: transaction.amount.amount * rate, currency: target)
    }

    private func eurRate(of currency: CurrencyCode) -> Decimal? {
        if currency == .eur { return 1 }
        return eurPerUnit[currency]
    }
}

/// Historische EZB-Referenzkurse je Tag (1 Einheit → EUR).
struct DailyFXRates: Sendable, Equatable {
    /// Wie weit ein Tag zurückgreifen darf (Wochenende, Feiertage).
    static let maximumLookbackDays = 7

    /// Aufsteigend sortiert, Tag als yyyymmdd.
    private let days: [Int]
    private let ratesByDay: [Int: [CurrencyCode: Decimal]]

    init(_ ratesByDay: [Int: [CurrencyCode: Decimal]]) {
        self.ratesByDay = ratesByDay.filter { !$0.value.isEmpty }
        self.days = self.ratesByDay.keys.sorted()
    }

    var isEmpty: Bool { days.isEmpty }
    var dayKeys: [Int] { days }
    func rates(forDayKey key: Int) -> [CurrencyCode: Decimal]? { ratesByDay[key] }

    /// Tag einer Buchung als yyyymmdd in der Kalenderzeitzone des Nutzers.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    func rates(on date: Date, calendar: Calendar = .current) -> [CurrencyCode: Decimal]? {
        let key = Self.dayKey(date, calendar: calendar)
        // Letzter Tag ≤ key (binäre Suche).
        var low = 0
        var high = days.count
        while low < high {
            let mid = (low + high) / 2
            if days[mid] <= key { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let found = days[low - 1]
        guard let foundDate = calendar.date(from: Self.components(found)),
              let wanted = calendar.date(from: Self.components(key)),
              let gap = calendar.dateComponents([.day], from: foundDate, to: wanted).day,
              gap <= Self.maximumLookbackDays else { return nil }
        return ratesByDay[found]
    }

    private static func components(_ key: Int) -> DateComponents {
        DateComponents(year: key / 10_000, month: key / 100 % 100, day: key % 100)
    }
}
