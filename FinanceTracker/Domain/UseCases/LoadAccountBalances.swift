import Foundation

struct AccountSummary: Identifiable, Hashable, Sendable {
    let account: Account
    let netMovement: Money
    /// Aktueller Stand aus gemeldetem Stand oder Anfangsbestand; `nil`,
    /// wenn das Konto keinen hat.
    let balance: Money?
    let balanceBasis: AccountBalanceCalculator.Basis?
    /// Zeitpunkt des zuletzt gemeldeten Stands.
    let balanceReportedAt: Date?
    /// Gemeldeter Stand in anderer Währung, aus dem `balance` umgerechnet ist.
    var balanceConvertedFrom: Money? = nil
    let foreignCurrencies: Set<CurrencyCode>
    let transactionCount: Int

    var id: UUID { account.id }
}

struct AccountBalances: Sendable {
    let accounts: [Account]
    /// Aktive Konten, nach Namen sortiert.
    let active: [AccountSummary]
    /// Deaktivierte Konten (nach „Verbindung trennen"), meiste Buchungen
    /// zuerst. Ohne Stand: sie zählen nicht zum Gesamtstand.
    let inactive: [AccountSummary]
}

/// Konten samt Bewegungssumme und aktuellem Stand. Eine Quelle für die
/// Konten-Seite und den Gesamtstand der Übersicht.
struct LoadAccountBalances: Sendable {
    private let accountRepository: any AccountRepository
    private let transactionRepository: any TransactionRepository

    init(accountRepository: any AccountRepository, transactionRepository: any TransactionRepository) {
        self.accountRepository = accountRepository
        self.transactionRepository = transactionRepository
    }

    /// `converter` rechnet gemeldete Stände in fremder Währung um (sichtbar
    /// markiert); ohne ihn zählen sie nicht.
    func execute(converter: CurrencyConverter? = nil, calendar: Calendar = .current) async throws -> AccountBalances {
        async let accountsTask = accountRepository.accounts()
        // Pushdown (Roadmap #179): Nur die für Bewegungen nötigen Felder
        // laden statt aller vollständigen Transaktionen.
        async let movementsTask = transactionRepository.accountMovementRows()
        let accounts = try await accountsTask
        let movements = try await movementsTask

        var totalsByAccount: [UUID: (sum: Decimal, foreign: Set<CurrencyCode>, count: Int)] = [:]
        var movementsByAccount: [UUID: [AccountBalanceCalculator.Movement]] = [:]
        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        for row in movements {
            guard let status = TransactionStatus(rawValue: row.statusRaw),
                  status != .reversed && status != .cancelled else { continue }
            guard let amount = Decimal(string: row.amountValue),
                  let account = accountsByID[row.accountID] else { continue }

            let currency = CurrencyCode(row.currencyRaw)
            var entry = totalsByAccount[row.accountID] ?? (Decimal(0), [], 0)
            if currency == account.currency {
                entry.sum += amount
                if account.openingBalance != nil || account.reportedBalance != nil {
                    movementsByAccount[row.accountID, default: []].append(.init(date: row.date, amount: amount))
                }
            } else {
                entry.foreign.insert(currency)
            }
            entry.count += 1
            totalsByAccount[row.accountID] = entry
        }

        func summary(_ account: Account, withBalance: Bool) -> AccountSummary {
            let entry = totalsByAccount[account.id]
            let result = withBalance
                ? AccountBalanceCalculator.balance(
                    for: account,
                    movements: movementsByAccount[account.id] ?? [],
                    converter: converter,
                    calendar: calendar
                )
                : nil
            return AccountSummary(
                account: account,
                netMovement: Money(amount: entry?.sum ?? Decimal(0), currency: account.currency),
                balance: result.map { Money(amount: $0.amount, currency: account.currency) },
                balanceBasis: result?.basis,
                balanceReportedAt: result?.reportedAt,
                balanceConvertedFrom: result?.convertedFrom,
                foreignCurrencies: entry?.foreign ?? [],
                transactionCount: entry?.count ?? 0
            )
        }

        let active = accounts.filter(\.isActive)
            .map { summary($0, withBalance: true) }
            .sorted { $0.account.name.localizedCaseInsensitiveCompare($1.account.name) == .orderedAscending }
        let inactive = accounts.filter { !$0.isActive }
            .map { summary($0, withBalance: false) }
            .sorted { $0.transactionCount > $1.transactionCount }
        return AccountBalances(accounts: accounts, active: active, inactive: inactive)
    }
}
