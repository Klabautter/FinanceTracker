import Foundation

/// Eine Frage in normaler Sprache („Wie viel für Restaurants im Sommer?",
/// „Was habe ich letzten Monat bei REWE ausgegeben?"), lokal in Zeitraum,
/// Kategorie, Händler und Richtung übersetzt. Zeitraum, Händler und
/// wörtlich genannte Kategorien erkennen feste Regeln; für freie
/// Formulierungen („Essen gehen") fragt die App das Sprachmodell des Geräts
/// (`FinanceQuestionInterpreter`), das nur unter den vorhandenen Kategorien
/// wählen kann. Gerechnet wird immer mit den Regeln der App, nie vom Modell.
struct FinanceQuestion: Equatable, Sendable {
    enum Measure: Equatable, Sendable {
        case spending
        case income
    }

    var measure: Measure = .spending
    var period: DateInterval
    /// Lesbare Beschreibung des Zeitraums („Sommer 2026").
    var periodLabel: String
    var categoryIDs: Set<UUID> = []
    var categoryNames: [String] = []
    var merchantKey: String?
    var merchantName: String?
}

struct FinanceAnswer: Equatable, Sendable {
    let question: FinanceQuestion
    let total: Decimal
    let currency: CurrencyCode
    let transactionIDs: [UUID]
    /// Buchungen in Fremdwährung ohne Kurs (nicht in der Summe).
    let excludedCount: Int
}

/// Versteht freie Formulierungen einer Frage. Läuft auf dem Gerät; wo es
/// kein Modell gibt, bleibt es bei den festen Regeln.
protocol FinanceQuestionInterpreter: Sendable {
    /// Ob auf diesem Gerät gerade ein Modell bereitsteht.
    var isAvailable: Bool { get }

    /// Die Kategorie aus `categoryNames`, nach der die Frage fragt.
    /// - Returns: `nil`, wenn die Frage keine davon meint.
    func categoryName(inQuestion question: String, categoryNames: [String]) async -> String?
}

enum FinanceQuestionParser {
    private static let months: [(names: [String], month: Int)] = [
        (["januar", "jänner", "january", "jan"], 1), (["februar", "february", "feb"], 2),
        (["märz", "maerz", "march", "mar"], 3), (["april", "apr"], 4), (["mai", "may"], 5),
        (["juni", "june", "jun"], 6), (["juli", "july", "jul"], 7), (["august", "aug"], 8),
        (["september", "sept", "sep"], 9), (["oktober", "october", "okt", "oct"], 10),
        (["november", "nov"], 11), (["dezember", "december", "dez", "dec"], 12)
    ]

    static func parse(
        _ text: String,
        categories: [Category],
        merchantNames: [String],
        now: Date,
        calendar: Calendar = .current
    ) -> FinanceQuestion {
        let normalized = normalize(text)
        let words = Set(normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))

        var question = defaultPeriod(now: now, calendar: calendar)
        if let period = period(in: normalized, words: words, now: now, calendar: calendar) {
            question.period = period.interval
            question.periodLabel = period.label
        }
        if ["eingenommen", "einnahmen", "einkommen", "verdient", "income", "earned"].contains(where: words.contains) {
            question.measure = .income
        }

        // Kategorien: Name oder Wortstamm (erste fünf Buchstaben) im Text.
        for category in categories {
            let key = normalize(category.name)
            guard key.count >= 3 else { continue }
            let stem = String(key.prefix(5))
            if normalized.contains(key) || words.contains(where: { $0.count >= 4 && ($0.hasPrefix(stem) || stem.hasPrefix($0)) && key.count >= 4 }) {
                question.categoryIDs.insert(category.id)
                question.categoryNames.append(category.name)
            }
        }
        // Eine Hauptkategorie umfasst ihre Unterkategorien.
        let parents = question.categoryIDs
        for category in categories where category.parentID.map(parents.contains) == true {
            question.categoryIDs.insert(category.id)
        }

        // Händler: längster bekannter Name, der als ganzes Wort vorkommt.
        let candidates = merchantNames
            .map { (name: $0, key: normalize($0)) }
            // Alle Wörter des Händlernamens müssen in der Frage stehen.
            .filter { candidate in
                let parts = candidate.key.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                return candidate.key.count >= 3 && !parts.isEmpty && parts.allSatisfy(words.contains)
            }
            .sorted { $0.key.count > $1.key.count }
        if let merchant = candidates.first {
            question.merchantKey = merchant.key
            question.merchantName = merchant.name
        }
        return question
    }

    /// Setzt die vom Sprachmodell erkannte Kategorie (samt Unterkategorien)
    /// in eine Frage ein, in der die Regeln keine gefunden haben.
    static func assigning(category: Category, to question: FinanceQuestion, categories: [Category]) -> FinanceQuestion {
        var result = question
        result.categoryIDs = [category.id]
        result.categoryNames = [category.name]
        for child in categories where child.parentID == category.id {
            result.categoryIDs.insert(child.id)
        }
        return result
    }

    /// - Parameter splitLines: Positionen aufgeteilter Buchungen. Fragt die
    ///   Frage nach einer Kategorie, zählt eine aufgeteilte Buchung nur mit
    ///   den Positionen dieser Kategorie: dieselbe Zerlegung wie in Analyse
    ///   und Budgets (AGENTS #28), sonst zeigten beide verschiedene Summen.
    static func answer(
        _ question: FinanceQuestion,
        transactions: [Transaction],
        splitLines: [TransactionSplitLine] = [],
        baseCurrency: CurrencyCode,
        converter: CurrencyConverter
    ) -> FinanceAnswer {
        let policy = CashflowPolicy.shared
        let splitsByParent = Dictionary(grouping: splitLines, by: \.parentTransactionID)
        var total: Decimal = 0
        var ids: [UUID] = []
        var excluded = 0
        for txn in transactions where txn.status.isEffective && !policy.isExcluded(txn) {
            guard question.period.containsHalfOpen(txn.displayDate) else { continue }
            if let merchantKey = question.merchantKey,
               !normalize(txn.effectiveMerchantName).contains(merchantKey) { continue }

            // Ohne Kategoriefrage zählt die Buchung als Ganzes. Mit
            // Kategoriefrage zählen bei einer aufgeteilten Buchung ihre
            // passenden Positionen, sonst die Buchung mit ihrer Kategorie.
            var parts = [txn]
            if !question.categoryIDs.isEmpty {
                if let lines = splitsByParent[txn.id], !lines.isEmpty {
                    let sign: Decimal = txn.amount.amount < 0 ? -1 : 1
                    parts = lines
                        .filter { $0.categoryID.map(question.categoryIDs.contains) == true }
                        .map { line in
                            var part = txn
                            part.categoryID = line.categoryID
                            part.amount = Money(amount: sign * line.amount, currency: txn.amount.currency)
                            return part
                        }
                } else if txn.categoryID.map(question.categoryIDs.contains) != true {
                    continue
                }
            }

            var counted = false
            var missingRate = false
            for part in parts {
                let delta: Decimal
                switch (question.measure, policy.contribution(for: part)) {
                case (.spending, .spending(let value)): delta = value
                case (.income, .income(let value)): delta = value
                default: continue
                }
                guard let converted = converter.convert(
                    Transaction.convertible(amount: delta, from: part), to: baseCurrency
                ) else {
                    missingRate = true
                    continue
                }
                total += converted.amount
                counted = true
            }
            if counted { ids.append(txn.id) }
            if missingRate { excluded += 1 }
        }
        return FinanceAnswer(question: question, total: total, currency: baseCurrency, transactionIDs: ids, excludedCount: excluded)
    }

    // MARK: - Zeitraum

    private static func defaultPeriod(now: Date, calendar: Calendar) -> FinanceQuestion {
        let start = calendar.dateInterval(of: .month, for: now)?.start ?? now
        return FinanceQuestion(
            period: DateInterval(start: start, end: calendar.date(byAdding: .month, value: 1, to: start) ?? now),
            periodLabel: String(localized: "diesen Monat")
        )
    }

    private static func period(
        in text: String, words: Set<String>, now: Date, calendar: Calendar
    ) -> (interval: DateInterval, label: String)? {
        let year = calendar.component(.year, from: now)
        let explicitYear = words.compactMap(Int.init).first { (2000...2100).contains($0) }

        func month(_ m: Int, _ y: Int) -> DateInterval? {
            guard let start = calendar.date(from: DateComponents(year: y, month: m, day: 1)),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
        func months(from m: Int, count: Int, year y: Int) -> DateInterval? {
            guard let start = calendar.date(from: DateComponents(year: y, month: m, day: 1)),
                  let end = calendar.date(byAdding: .month, value: count, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }

        if text.contains("letzten monat") || text.contains("vormonat") || text.contains("last month") {
            guard let previous = calendar.date(byAdding: .month, value: -1, to: now),
                  let interval = calendar.dateInterval(of: .month, for: previous) else { return nil }
            return (interval, String(localized: "letzten Monat"))
        }
        if text.contains("dieses jahr") || text.contains("diesem jahr") || text.contains("this year") {
            guard let interval = calendar.dateInterval(of: .year, for: now) else { return nil }
            return (interval, String(localized: "dieses Jahr"))
        }
        if text.contains("letztes jahr") || text.contains("letzten jahr") || text.contains("vorjahr") || text.contains("last year") {
            guard let previous = calendar.date(byAdding: .year, value: -1, to: now),
                  let interval = calendar.dateInterval(of: .year, for: previous) else { return nil }
            return (interval, String(localized: "letztes Jahr"))
        }
        if let match = text.range(of: #"letzten (\d+) tage"#, options: .regularExpression) {
            let days = Int(text[match].filter(\.isNumber)) ?? 30
            guard let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)),
                  let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
            return (DateInterval(start: start, end: end), String(localized: "letzte \(days) Tage"))
        }
        // Jahreszeiten: Sommer = Juni–August usw.; ohne Jahr die letzte
        // begonnene Jahreszeit dieses Namens.
        let seasons: [(names: [String], start: Int, label: String)] = [
            (["frühling", "fruehling", "frühjahr", "spring"], 3, String(localized: "Frühling")),
            (["sommer", "summer"], 6, String(localized: "Sommer")),
            (["herbst", "autumn", "fall"], 9, String(localized: "Herbst")),
            (["winter"], 12, String(localized: "Winter"))
        ]
        for season in seasons where season.names.contains(where: words.contains) {
            var y = explicitYear ?? year
            if explicitYear == nil, let start = calendar.date(from: DateComponents(year: y, month: season.start, day: 1)), start > now {
                y -= 1
            }
            guard let interval = months(from: season.start, count: 3, year: y) else { return nil }
            return (interval, "\(season.label) \(y)")
        }
        for entry in Self.months where entry.names.contains(where: words.contains) {
            var y = explicitYear ?? year
            if explicitYear == nil, let start = calendar.date(from: DateComponents(year: y, month: entry.month, day: 1)), start > now {
                y -= 1
            }
            guard let interval = month(entry.month, y) else { return nil }
            let label = interval.start.formatted(.dateTime.month(.wide).year())
            return (interval, label)
        }
        return nil
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Optional where Wrapped == Bool {
    var isTrue: Bool { self == true }
}

private extension Transaction {
    /// Betrag mit Vorzeichen-unabhängiger Größe, aber Währung und Datum der
    /// Buchung (für die Umrechnung zum Kurs des Buchungstags).
    static func convertible(amount: Decimal, from txn: Transaction) -> Transaction {
        var copy = txn
        copy.amount = Money(amount: amount, currency: txn.amount.currency)
        return copy
    }
}
