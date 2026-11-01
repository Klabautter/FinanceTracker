import Foundation

/// Kontostand aus den Kopf- oder Fußzeilen eines Kontoauszugs, z. B.
/// „Kontostand am 30.09.2026  2.415,65 EUR", „Neuer Saldo per 30.09.2026"
/// oder „Closing balance on 30/09/2026  1,234.56".
///
/// Viele Auszüge nennen den Stand nur dort und nicht je Buchung. Gilt nur
/// mit Datum in derselben Zeile, hinter dem Stichwort; der Stand mit dem
/// jüngsten Datum zählt.
/// Nennt der Auszug für diesen Tag verschiedene Beträge, gibt es keinen
/// Stand statt eines geratenen (#17). Verfügbare Beträge (mit Dispo- oder
/// Kreditrahmen) sind kein Guthaben und zählen nicht.
enum StatementBalanceExtractor {
    private static let keywords = [
        "KONTOSTAND", "SALDO", "ENDSALDO", "GUTHABEN AM",
        "CLOSING BALANCE", "ENDING BALANCE", "ACCOUNT BALANCE", "BALANCE ON", "BALANCE AS OF", "BALANCE AT"
    ]
    private static let excluded = ["VERFUGBAR", "VERFUEGBAR", "AVAILABLE", "DISPO", "KREDITRAHMEN", "LIMIT"]

    private static let datePatterns: [(regex: NSRegularExpression, order: (day: Int, month: Int, year: Int))] = [
        (try! NSRegularExpression(pattern: #"\b(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})\b"#), (1, 2, 3)),
        (try! NSRegularExpression(pattern: #"\b(\d{4})-(\d{2})-(\d{2})\b"#), (3, 2, 1)),
        (try! NSRegularExpression(pattern: #"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#), (1, 2, 3))
    ]
    /// Betrag mit zwei Nachkommastellen, optional mit Tausendertrennern
    /// und Vorzeichen davor oder dahinter („2.415,65-").
    private static let amountRegex = try! NSRegularExpression(
        pattern: #"([-+−]?)\s?(\d{1,3}(?:[.,'’ ]\d{3})*[.,]\d{2})(?!\d)\s?(-?)"#
    )
    private static let currencyRegex = try! NSRegularExpression(pattern: #"\b([A-Z]{3})\b|([€$£])"#)

    static func closingBalance(
        in lines: [String],
        currency: CurrencyCode,
        calendar: Calendar = .current
    ) -> ReportedBalance? {
        var candidates: [(day: Date, amount: Decimal)] = []
        for line in lines {
            guard !excluded.contains(where: normalized(line).contains),
                  let (day, dateRange) = date(in: line, calendar: calendar) else { continue }
            // Das Stichwort steht vor dem Datum („Kontostand am …"); eine
            // Buchungszeile beginnt mit dem Datum und zählt nicht.
            let beforeDate = normalized((line as NSString).substring(to: dateRange.location))
            guard keywords.contains(where: beforeDate.contains) else { continue }
            let rest = (line as NSString).replacingCharacters(in: dateRange, with: " ")
            guard currencyMatches(rest, currency: currency),
                  let amount = lastAmount(in: rest) else { continue }
            candidates.append((day, amount))
        }
        guard let latest = candidates.map(\.day).max() else { return nil }
        let amounts = Set(candidates.filter { $0.day == latest }.map(\.amount))
        guard amounts.count == 1, let amount = amounts.first,
              let nextDay = calendar.date(byAdding: .day, value: 1, to: latest) else { return nil }
        // Stand zum Ende des Tages: Buchungen dieses Tages stecken schon darin.
        return ReportedBalance(
            amount: Money(amount: amount, currency: currency),
            asOf: nextDay.addingTimeInterval(-1),
            source: .file
        )
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE")).uppercased()
    }

    private static func date(in line: String, calendar: Calendar) -> (Date, NSRange)? {
        let range = NSRange(line.startIndex..., in: line)
        for pattern in datePatterns {
            guard let match = pattern.regex.firstMatch(in: line, range: range) else { continue }
            func value(_ group: Int) -> Int? {
                Range(match.range(at: group), in: line).flatMap { Int(line[$0]) }
            }
            guard let day = value(pattern.order.day), let month = value(pattern.order.month),
                  var year = value(pattern.order.year) else { continue }
            if year < 100 { year += 2000 }
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            guard let date = calendar.date(from: components),
                  calendar.component(.day, from: date) == day,
                  calendar.component(.month, from: date) == month else { continue }
            return (calendar.startOfDay(for: date), match.range)
        }
        return nil
    }

    private static func lastAmount(in text: String) -> Decimal? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = amountRegex.matches(in: text, range: range).last,
              let numberRange = Range(match.range(at: 2), in: text) else { return nil }
        var number = String(text[numberRange])
        // Tausendertrenner als Leerzeichen oder Apostroph entfernen; Punkt
        // und Komma löst DecimalParser auf.
        number.removeAll { $0 == " " || $0 == "'" || $0 == "’" }
        guard let value = DecimalParser.parse(number) else { return nil }
        let leading = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
        let trailing = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
        let negative = leading == "-" || leading == "−" || trailing == "-"
        return negative ? -value : value
    }

    /// Ohne Währungsangabe gilt die Kontowährung; eine andere Währung zählt
    /// nicht (#19).
    private static func currencyMatches(_ text: String, currency: CurrencyCode) -> Bool {
        let symbols: [String: String] = ["€": "EUR", "$": "USD", "£": "GBP"]
        let range = NSRange(text.startIndex..., in: text)
        let found = currencyRegex.matches(in: text, range: range).compactMap { match -> String? in
            if let code = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
               CurrencyConverter.referenceEURRates.keys.contains(CurrencyCode(code)) || code == "EUR" {
                return code
            }
            return Range(match.range(at: 2), in: text).flatMap { symbols[String(text[$0])] }
        }
        return found.isEmpty || found.contains(currency.rawValue)
    }
}
