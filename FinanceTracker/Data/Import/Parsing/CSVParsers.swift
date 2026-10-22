import Foundation

enum CSVDateParser {
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let utc = TimeZone(identifier: "UTC")

    private static let formatterBox = DateFormatterBox()

    /// - Parameter monthFirst: Die Datei schreibt Monat vor Tag („10/15/2026",
    ///   US-Banken). Wird pro Datei mit `prefersMonthFirst(in:)` bestimmt.
    static func parse(_ raw: String?, monthFirst: Bool = false) -> Date? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }

        let formatters = monthFirst
            ? formatterBox.monthFirstFormatters + formatterBox.dateFormatters
            : formatterBox.dateFormatters
        for formatter in formatters {
            if let date = formatter.date(from: value), formatter.string(from: date) == value {
                return date
            }
        }
        if let date = formatterBox.iso8601.date(from: value) {
            return date
        }
        return parseWithMonthName(value)
    }

    /// Steht in einer Datei mit „/" je ein Tag über 12 an zweiter Stelle
    /// („10/15/2026"), schreibt sie Monat zuerst. Ein Tag über 12 vorn
    /// („15/10/2026") heißt Tag zuerst; ohne Hinweis bleibt es beim Tag.
    static func prefersMonthFirst(in samples: [String]) -> Bool {
        var monthFirst = false
        for sample in samples {
            let parts = sample.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first?
                .split(separator: "/").compactMap { Int($0) } ?? []
            guard parts.count == 3 else { continue }
            if parts[0] > 12 { return false }
            if parts[1] > 12 { monthFirst = true }
        }
        return monthFirst
    }

    private static let monthNumbers: [String: Int] = [
        "jan": 1, "januar": 1, "january": 1, "feb": 2, "februar": 2, "february": 2,
        "mar": 3, "marz": 3, "maerz": 3, "march": 3, "apr": 4, "april": 4, "mai": 5, "may": 5,
        "jun": 6, "juni": 6, "june": 6, "jul": 7, "juli": 7, "july": 7, "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9, "okt": 10, "oct": 10, "oktober": 10, "october": 10,
        "nov": 11, "november": 11, "dez": 12, "dec": 12, "dezember": 12, "december": 12
    ]

    /// Ausgeschriebene oder abgekürzte Monate, wie sie in Kontoauszügen
    /// stehen: „01 Juli 2024", „12. Okt. 2026", „3 Sept 2026".
    private static func parseWithMonthName(_ value: String) -> Date? {
        let parts = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard parts.count == 3,
              let day = Int(parts[0]), (1...31).contains(day),
              let month = monthNumbers[parts[1]],
              parts[2].count == 4, let year = Int(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc ?? .gmt
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else {
            return nil
        }
        return date
    }
}

enum CSVMoneyParser {
    /// Dezimaltrennzeichen einer Datei, aus allen Beträgen einer Spalte
    /// abgeleitet: „-12,30" verrät Komma, „-12.30" Punkt. `nil`, wenn die
    /// Datei es nicht verrät (z. B. nur ganze Zahlen).
    static func decimalSeparator(in samples: [String]) -> Character? {
        var comma = 0
        var dot = 0
        for sample in samples {
            let core = sample.filter { $0.isNumber || $0 == "," || $0 == "." }
            guard let last = core.lastIndex(where: { $0 == "," || $0 == "." }) else { continue }
            let decimals = core[core.index(after: last)...].count
            guard (1...2).contains(decimals) else { continue }
            if core[last] == "," { comma += 1 } else { dot += 1 }
        }
        if comma == 0 && dot == 0 { return nil }
        return comma >= dot ? "," : "."
    }

    private static let negativeMarkers: Set<String> = ["S", "D", "DR", "DB", "SOLL", "DEBIT", "DBIT"]
    private static let positiveMarkers: Set<String> = ["H", "C", "CR", "HABEN", "CREDIT", "CRDT"]
    private static let currencySymbols = CharacterSet(charactersIn: "€$£¥₣₤₹₽₺₩₪₫฿₴₸₱")

    /// Liest einen Geldbetrag streng: Vorzeichen vorn oder hinten („12,50-"),
    /// Klammern als Minus („(120.50)"), Soll/Haben-Kennzeichen („45,10 S"),
    /// Währungszeichen und -codes werden ignoriert. Tausendertrenner müssen
    /// Dreiergruppen bilden: „15.10.2026" ist kein Betrag. Alles andere
    /// ergibt `nil` statt eines geratenen Werts.
    ///
    /// - Parameter decimalSeparator: Dezimaltrennzeichen der Datei, falls
    ///   bekannt. Ohne Angabe gilt ein einzelnes Trennzeichen als Dezimal-
    ///   trenner (wie bisher), mit Angabe ist „2.000" in einer Komma-Datei
    ///   zweitausend.
    static func parse(_ raw: String?, decimalSeparator: Character? = nil) -> Decimal? {
        guard let original = raw else { return nil }
        var value = original
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        var negative = false

        // Buchstaben: Währungscodes ignorieren, Soll/Haben auswerten, sonst ungültig.
        let letterRuns = value.split(whereSeparator: { !$0.isLetter }).map { String($0).uppercased() }
        for run in letterRuns {
            if run.count == 3, CurrencyCode(run).rawValue == run, !negativeMarkers.contains(run), !positiveMarkers.contains(run) {
                continue
            }
            if negativeMarkers.contains(run) { negative = true; continue }
            if positiveMarkers.contains(run) { continue }
            return nil
        }
        value = String(value.unicodeScalars.filter {
            !CharacterSet.letters.contains($0) && !currencySymbols.contains($0)
        }.map(Character.init))
        // Leerzeichen und Hochkomma als Tausendertrenner („1 234,56", „1'234.56").
        value = value.filter { !$0.isWhitespace && $0 != "'" && $0 != "\u{00A0}" && $0 != "\u{202F}" }

        if value.hasPrefix("("), value.hasSuffix(")") {
            negative = true
            value = String(value.dropFirst().dropLast())
        }
        if let first = value.first, first == "-" || first == "+" {
            if first == "-" { negative.toggle() }
            value.removeFirst()
        }
        if let last = value.last, last == "-" || last == "+" {
            if last == "-" { negative.toggle() }
            value.removeLast()
        }

        guard !value.isEmpty,
              value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }),
              value.first?.isNumber == true || value.first == "." || value.first == ",",
              value.last?.isNumber == true else { return nil }

        guard let normalized = normalizedNumber(value, decimalSeparator: decimalSeparator),
              let number = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return negative ? -number : number
    }

    /// „1.234,56" → „1234.56". Prüft, dass Tausendergruppen dreistellig sind.
    private static func normalizedNumber(_ value: String, decimalSeparator hint: Character?) -> String? {
        let commas = value.filter { $0 == "," }.count
        let dots = value.filter { $0 == "." }.count

        let decimal: Character?
        switch (commas, dots) {
        case (0, 0):
            decimal = nil
        case (_, 0) where commas > 1, (0, _) where dots > 1:
            decimal = nil // nur Tausendertrenner
        case (1, 0), (0, 1):
            let separator: Character = commas == 1 ? "," : "."
            if let hint {
                decimal = separator == hint ? separator : nil
            } else {
                decimal = separator
            }
        default:
            // Beide vorhanden: das letzte ist der Dezimaltrenner, und es darf nur einmal vorkommen.
            guard let last = value.last(where: { $0 == "," || $0 == "." }),
                  value.filter({ $0 == last }).count == 1 else { return nil }
            decimal = last
        }

        var integerPart = value
        var fraction = ""
        if let decimal, let index = value.lastIndex(of: decimal) {
            integerPart = String(value[..<index])
            fraction = String(value[value.index(after: index)...])
            guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber) else { return nil }
        }
        let groups = integerPart.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "." })
        if groups.count > 1 {
            guard let first = groups.first, (1...3).contains(first.count),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        }
        let digits = groups.joined()
        let integerDigits = digits.isEmpty ? "0" : digits
        return fraction.isEmpty ? integerDigits : integerDigits + "." + fraction
    }

    static func parseMoney(
        _ amountRaw: String?,
        currencyRaw: String?,
        fallback: CurrencyCode,
        decimalSeparator: Character? = nil
    ) -> Money? {
        guard let amount = parse(amountRaw, decimalSeparator: decimalSeparator) else { return nil }
        let currency = currencyRaw.flatMap { raw -> CurrencyCode? in
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard (3...3).contains(cleaned.count), cleaned.allSatisfy({ $0.isLetter }) else { return nil }
            return CurrencyCode(cleaned)
        } ?? fallback
        return Money(amount: amount, currency: currency)
    }
}


final class DateFormatterBox: @unchecked Sendable {
    let dateFormatters: [DateFormatter]
    let monthFirstFormatters: [DateFormatter]
    let iso8601: ISO8601DateFormatter

    init() {
        let formats = [
            "dd.MM.yyyy",
            "dd.MM.yyyy HH:mm",
            "dd.MM.yyyy HH:mm:ss",
            "yyyy-MM-dd",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss 'UTC'",
            "yyyy-MM-dd HH:mm:ss 'GMT'",
            "dd/MM/yyyy",
            "dd.MM.yy",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "dd.MM.yyyy, HH:mm",
            "dd-MM-yyyy",
            "yyyy/MM/dd",
            // Tag und Monat ohne führende Null („1.9.2026").
            "d.M.yyyy",
            "d.M.yy",
            "d/M/yyyy"
        ]
        dateFormatters = Self.makeFormatters(formats)
        monthFirstFormatters = Self.makeFormatters([
            "MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy",
            "MM/dd/yyyy HH:mm", "MM/dd/yyyy HH:mm:ss", "MM-dd-yyyy"
        ])

        iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime]
    }

    private static func makeFormatters(_ formats: [String]) -> [DateFormatter] {
        let posix = Locale(identifier: "en_US_POSIX")
        let utc = TimeZone(identifier: "UTC")
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = posix
            formatter.timeZone = utc
            formatter.isLenient = false
            if format.contains("yy") && !format.contains("yyyy") {
                formatter.twoDigitStartDate = Self.referenceDate
            }
            return formatter
        }
    }

    private static let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }()
}
