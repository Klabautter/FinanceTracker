import Foundation

/// Kontostand nach der letzten Buchung einer Datei, aus der Saldo-Spalte.
///
/// Mehrere Zeilen am letzten Tag ohne Uhrzeit lassen sich über die Kette
/// ordnen: Der Saldo einer Zeile ist der Saldo der vorigen plus ihr Betrag.
/// Bleibt danach mehr als ein Kandidat, ist die Reihenfolge unklar und es
/// gibt keinen Stand, statt einen zu raten (#17).
enum ImportedBalanceExtractor {
    static func latestBalance(in transactions: [ImportedTransaction], currency: CurrencyCode) -> ReportedBalance? {
        let rows = transactions.compactMap { row -> (date: Date, balance: Decimal, amount: Decimal)? in
            guard let balance = row.balanceAfter,
                  row.status == .booked,
                  row.amount.currency == currency,
                  let date = row.bookedAt ?? row.authorizedAt else { return nil }
            return (date, balance, row.amount.amount)
        }
        guard let latestDate = rows.map(\.date).max() else { return nil }
        let latest = rows.filter { $0.date == latestDate }
        // Kandidat ist eine Zeile, auf die keine andere desselben Zeitpunkts folgt.
        let candidates = latest.indices.filter { index in
            !latest.indices.contains { other in
                other != index && latest[other].balance == latest[index].balance + latest[other].amount
            }
        }
        guard candidates.count == 1 else { return nil }
        return ReportedBalance(
            amount: Money(amount: latest[candidates[0]].balance, currency: currency),
            asOf: latestDate,
            source: .file
        )
    }
}
