import Foundation

/// „Stand festlegen": Der Nutzer nennt den Kontostand, wie er am Ende des
/// Tages `date` ist (der Betrag in der App oder auf dem Kontoauszug). Daraus
/// wird der Anfangsbestand zu Beginn dieses Tages: der genannte Stand ohne
/// die Buchungen des Tages. `AccountBalanceCalculator` rechnet die Buchungen
/// ab dem Stichtag wieder dazu und zeigt so genau den genannten Stand.
struct SetAccountBalance: Sendable {
    let accountRepository: any AccountRepository
    let transactionRepository: any TransactionRepository

    @discardableResult
    func callAsFunction(
        _ balance: Decimal,
        for account: Account,
        on date: Date,
        calendar: Calendar = .current
    ) async throws -> Account {
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return account }
        var query = TransactionQuery()
        query.accountIDs = [account.id]
        query.dateInterval = DateInterval(start: dayStart, end: dayEnd)
        let dayMovements = try await transactionRepository.transactions(matching: query)
            .filter { $0.status.isEffective && $0.amount.currency == account.currency }
            .reduce(Decimal(0)) { $0 + $1.amount.amount }

        var updated = account
        updated.openingBalance = balance - dayMovements
        updated.openingBalanceDate = dayStart
        try await accountRepository.upsert([updated])
        return updated
    }
}
