import Foundation

/// Kontostand aus den Kopf- oder Fußzeilen eines Kontoauszugs, z. B.
/// „Kontostand am 30.09.2026  2.415,65 EUR", „Neuer Saldo per 30.09.2026"
/// oder „Closing balance on 30/09/2026  1,234.56".
///
/// Viele Auszüge nennen den Stand nur dort und nicht je Buchung. Gilt nur
/// mit Datum in derselben Zeile, hinter dem Stichwort; der Stand mit dem
/// jüngsten Datum zählt. Stehen Stichwort, Betrag und Datum untereinander,
/// setzt der PDF-Import sie vorher zu einer Zeile zusammen.
///
/// Der Stand behält die Währung, die der Auszug nennt (ohne Angabe die des
/// Kontos). Eine andere Währung als die des Kontos rechnet die Kontenliste
/// sichtbar um, nie still (#19).
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
    /// „31 Oct 2026", „1. September 2026", „30 Sept. 2026".
    private static let monthNameDate = try! NSRegularExpression(
        pattern: #"\b(\d{1,2})\.?\s+([A-Za-zÄäÖöÜü]{3,9})\.?\s+(\d{4})\b"#
    )
    private static let monthNames: [String: Int] = [
        "JAN": 1, "FEB": 2, "MAR": 3, "MAE": 3, "MRZ": 3, "APR": 4, "MAY": 5, "MAI": 5, "JUN": 6, "JUL": 7,
        "AUG": 8, "SEP": 9, "OCT": 10, "OKT": 10, "NOV": 11, "DEC": 12, "DEZ": 12
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
        var candidates: [(day: Date, amount: Money)] = []
        for line in lines {
            guard !excluded.contains(where: normalized(line).contains),
                  let (day, dateRange) = date(in: line, calendar: calendar) else { continue }
            // Das Stichwort steht vor dem Datum („Kontostand am …"); eine
            // Buchungszeile beginnt mit dem Datum und zählt nicht.
            let beforeDate = normalized((line as NSString).substring(to: dateRange.location))
            guard keywords.contains(where: beforeDate.contains) else { continue }
            let rest = (line as NSString).replacingCharacters(in: dateRange, with: " ")
            guard let lineCurrency = statedCurrency(in: rest, default: currency),
                  let amount = lastAmount(in: rest) else { continue }
            candidates.append((day, Money(amount: amount, currency: lineCurrency)))
        }
        guard let latest = candidates.map(\.day).max() else { return nil }
        let amounts = Set(candidates.filter { $0.day == latest }.map(\.amount))
        guard amounts.count == 1, let amount = amounts.first,
              let nextDay = calendar.date(byAdding: .day, value: 1, to: latest) else { return nil }
        // Stand zum Ende des Tages: Buchungen dieses Tages stecken schon darin.
        return ReportedBalance(
            amount: amount,
            asOf: nextDay.addingTimeInterval(-1),
            source: .file
        )
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE")).uppercased()
    }

    private static func date(in line: String, calendar: Calendar) -> (Date, NSRange)? {
        let range = NSRange(line.startIndex..., in: line)
        var found: [(day: Int, month: Int, year: Int, range: NSRange)] = []
        for pattern in datePatterns {
            guard let match = pattern.regex.firstMatch(in: line, range: range) else { continue }
            func value(_ group: Int) -> Int? {
                Range(match.range(at: group), in: line).flatMap { Int(line[$0]) }
            }
            guard let day = value(pattern.order.day), let month = value(pattern.order.month),
                  let year = value(pattern.order.year) else { continue }
            found.append((day, month, year, match.range))
        }
        for match in monthNameDate.matches(in: line, range: range) {
            guard let dayRange = Range(match.range(at: 1), in: line),
                  let nameRange = Range(match.range(at: 2), in: line),
                  let yearRange = Range(match.range(at: 3), in: line),
                  let day = Int(line[dayRange]), let year = Int(line[yearRange]) else { continue }
            // „März" wird zu „MARZ", „Maerz" bleibt „MAE".
            guard let month = monthNames[String(normalized(String(line[nameRange])).prefix(3))] else { continue }
            found.append((day, month, year, match.range))
        }
        // Das erste Datum der Zeile zählt.
        for candidate in found.sorted(by: { $0.range.location < $1.range.location }) {
            let year = candidate.year < 100 ? candidate.year + 2000 : candidate.year
            var components = DateComponents()
            components.year = year
            components.month = candidate.month
            components.day = candidate.day
            guard let date = calendar.date(from: components),
                  calendar.component(.day, from: date) == candidate.day,
                  calendar.component(.month, from: date) == candidate.month else { continue }
            return (calendar.startOfDay(for: date), candidate.range)
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

    /// Die genannte Währung; ohne Angabe die des Kontos. Mehrere
    /// verschiedene Währungen in einer Zeile sind unklar (`nil`).
    private static func statedCurrency(in text: String, default currency: CurrencyCode) -> CurrencyCode? {
        let symbols: [String: String] = ["€": "EUR", "$": "USD", "£": "GBP"]
        let range = NSRange(text.startIndex..., in: text)
        let found = Set(currencyRegex.matches(in: text, range: range).compactMap { match -> String? in
            if let code = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
               CurrencyConverter.referenceEURRates.keys.contains(CurrencyCode(code)) || code == "EUR" {
                return code
            }
            return Range(match.range(at: 2), in: text).flatMap { symbols[String(text[$0])] }
        })
        guard found.count <= 1 else { return nil }
        return found.first.map(CurrencyCode.init) ?? currency
    }
}
