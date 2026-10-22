import Foundation

struct AccountSummary: Identifiable, Hashable, Sendable {
    let account: Account
    let netMovement: Money
    /// Aktueller Stand (Anfangsbestand + Bewegungen ab Stichtag); nur bei
    /// Konten mit erfasstem Anfangsbestand.
    let balance: Money?
    let foreignCurrencies: Set<CurrencyCode>
    let transactionCount: Int

    var id: UUID { account.id }
}

@MainActor
@Observable
final class AccountsModel {
    let dependencies: AppDependencies
    /// Single Source für Consent/SCA-Einstufung (T-10d, RTS Art. 10),
    /// keine duplizierte Ablauf-Logik neben `BankConnectModel` (#11).
    private let healthEvaluator = ConnectionHealthEvaluator()

    private(set) var accounts: [AccountSummary] = []
    /// Konten ohne Verbindung (nach „Verbindung trennen"). Ihre Buchungen
    /// zählen weiter in allen Auswertungen mit, deshalb bleiben sie sichtbar
    /// und lassen sich hier samt Buchungen löschen.
    private(set) var disconnectedAccounts: [AccountSummary] = []
    private(set) var connections: [Connection] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    var dataRevision: Int { dependencies.changeTracker.revision }

    /// Ablageort der Beleg-Dateien; `nil` = Standardverzeichnis der App.
    private let attachmentsBaseDirectory: URL?

    init(dependencies: AppDependencies, attachmentsBaseDirectory: URL? = nil) {
        self.dependencies = dependencies
        self.attachmentsBaseDirectory = attachmentsBaseDirectory
    }

    /// Verbindungen ohne gespeicherten Banknamen bekommen ihn aus der
    /// Institutions-ID, ohne Netzwerkzugriff und ohne Bankabruf.
    private func namedConnections(_ connections: [Connection]) async -> [Connection] {
        var named: [Connection] = []
        var changed: [Connection] = []
        for connection in connections {
            guard connection.institutionName == nil, let institutionID = connection.institutionID,
                  let name = dependencies.bankProviderFactory.makeBankDataProvider(for: connection)
                      .institutionDisplayName(forInstitutionID: institutionID) else {
                named.append(connection)
                continue
            }
            var updated = connection
            updated.institutionName = name
            named.append(updated)
            changed.append(updated)
        }
        if !changed.isEmpty {
            try? await dependencies.connectionRepository.upsert(changed)
        }
        return named
    }

    func load() async {
        guard !isLoading else { return }
        let signpost = PerfSignpost.signposter.beginInterval("AccountsLoad")
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            PerfSignpost.signposter.endInterval("AccountsLoad", signpost)
        }

        do {
            async let accountsTask = dependencies.accountRepository.accounts()
            async let connectionsTask = dependencies.connectionRepository.connections()
            // Pushdown (Roadmap #179): Nur die 4 für Bewegungen nötigen
            // Felder laden statt 50k vollständiger Transaktionen.
            async let movementsTask = dependencies.transactionRepository.accountMovementRows()

            let fetchedAccounts = try await accountsTask
            let fetchedConnections = try await connectionsTask
            let movements = try await movementsTask

            connections = await namedConnections(fetchedConnections).sorted { $0.updatedAt > $1.updatedAt }

            // Deaktivierte Konten (z. B. nach „Verbindung trennen" oder
            // Re-Connect-Dedup) stehen nicht zwischen den aktiven Konten,
            // sondern in einem eigenen Abschnitt „Getrennte Konten".
            let visibleAccounts = fetchedAccounts.filter(\.isActive)
            let inactiveAccounts = fetchedAccounts.filter { !$0.isActive }

            var totalsByAccount: [UUID: (sum: Decimal, foreign: Set<CurrencyCode>, count: Int)] = [:]
            var movementsByAccount: [UUID: [AccountBalanceCalculator.Movement]] = [:]
            let accountsByID = Dictionary(uniqueKeysWithValues: fetchedAccounts.map { ($0.id, $0) })
            for row in movements {
                guard let status = TransactionStatus(rawValue: row.statusRaw),
                      status != .reversed && status != .cancelled else { continue }
                guard let amount = Decimal(string: row.amountValue),
                      let account = accountsByID[row.accountID] else { continue }

                let currency = CurrencyCode(row.currencyRaw)
                var entry = totalsByAccount[row.accountID] ?? (Decimal(0), [], 0)
                if currency == account.currency {
                    entry.sum += amount
                    if account.openingBalance != nil {
                        movementsByAccount[row.accountID, default: []].append(.init(date: row.date, amount: amount))
                    }
                } else {
                    entry.foreign.insert(currency)
                }
                entry.count += 1
                totalsByAccount[row.accountID] = entry
            }

            accounts = visibleAccounts.map { account in
                let entry = totalsByAccount[account.id]
                let balance = AccountBalanceCalculator.balance(
                    openingBalance: account.openingBalance,
                    openingDate: account.openingBalanceDate,
                    movements: movementsByAccount[account.id] ?? []
                )
                return AccountSummary(
                    account: account,
                    netMovement: Money(amount: entry?.sum ?? Decimal(0), currency: account.currency),
                    balance: balance.map { Money(amount: $0, currency: account.currency) },
                    foreignCurrencies: entry?.foreign ?? [],
                    transactionCount: entry?.count ?? 0
                )
            }
            .sorted { $0.account.name.localizedCaseInsensitiveCompare($1.account.name) == .orderedAscending }

            disconnectedAccounts = inactiveAccounts.map { account in
                let entry = totalsByAccount[account.id]
                return AccountSummary(
                    account: account,
                    netMovement: Money(amount: entry?.sum ?? Decimal(0), currency: account.currency),
                    balance: nil,
                    foreignCurrencies: entry?.foreign ?? [],
                    transactionCount: entry?.count ?? 0
                )
            }
            .sorted { $0.transactionCount > $1.transactionCount }
        } catch {
            errorMessage = String(localized: "Die Konten konnten nicht geladen werden.")
        }
    }

    func sync(connection: Connection) async -> String? {
        do {
            // WP-MacUX: Provider-Routing nach Connection.provider:
            // Eine Enable-Banking-Connection darf nicht gegen die
            // GoCardless-API synchronisieren.
            let provider = dependencies.bankProviderFactory.makeBankDataProvider(for: connection)
            let service = BankSyncService(dependencies: dependencies, provider: provider)
            let result = try await service.sync(connection: connection)
            dependencies.changeTracker.markChanged()
            await load()
            return String(localized: "Sync fertig: \(result.importedCount) neu, \(result.updatedCount) aktualisiert.")
        } catch let error as BankProviderError {
            errorMessage = String(localized: "Sync fehlgeschlagen: \(Self.providerFailureMessage(for: error))")
            return nil
        } catch {
            errorMessage = String(localized: "Sync fehlgeschlagen: \(error.localizedDescription)")
            return nil
        }
    }

    /// WP-MacUX: „(FinanceTracker.BankProviderError-Fehler 2.)" ist
    /// unbenutzbar: HTTP-Status und Provider-Fehlerbody sind die konkrete
    /// Ursache (z. B. abgelaufene Session) und werden sichtbar gemacht.
    private static func providerFailureMessage(for error: BankProviderError) -> String {
        switch error {
        case .missingCredentials:
            return String(localized: "Keine Provider-Zugangsdaten hinterlegt. Bitte die Verbindung neu herstellen.")
        case .invalidResponse:
            return String(localized: "Der Provider hat eine unlesbare Antwort geschickt.")
        case .requestFailed(_, let status, let body):
            let detail = body.flatMap { body in
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : String(trimmed.prefix(160))
            }
            if let detail {
                return String(localized: "Die Bank-API hat HTTP \(status) gemeldet: \(detail).")
            }
            return String(localized: "Die Bank-API hat HTTP \(status) gemeldet.")
        }
    }

    func disconnect(connection: Connection) async {
        do {
            try await DisconnectBankConnection(
                accountRepository: dependencies.accountRepository,
                connectionRepository: dependencies.connectionRepository
            )(connection)
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            errorMessage = String(localized: "Verbindung konnte nicht getrennt werden.")
        }
    }

    /// Löscht ein getrenntes Konto samt Buchungen. Aktive Konten sind hier
    /// bewusst ausgeschlossen: Sie hängen an einer Verbindung oder werden
    /// vom Nutzer gepflegt.
    func deleteDisconnectedAccount(_ account: Account) async {
        guard !account.isActive else { return }
        await deleteAccountWithTransactions(account)
    }

    /// Selbst angelegte Konten (Bargeld, Karte ohne Anbindung …) darf der
    /// Nutzer jederzeit wieder entfernen. Konten einer Bankverbindung nicht:
    /// Sie kämen beim nächsten Abruf zurück; dafür gibt es „Verbindung
    /// trennen" und danach den Abschnitt „Getrennte Konten".
    func canDeleteManually(_ account: Account) -> Bool {
        // Auch beim Datei-Import angelegte Konten sind vom Nutzer erstellt.
        account.isActive && [.manual, .csvImport].contains(account.source) && account.connectionID == nil
    }

    /// Löscht ein manuelles Konto samt seiner Buchungen und Belege.
    func deleteManualAccount(_ account: Account) async {
        guard canDeleteManually(account) else { return }
        await deleteAccountWithTransactions(account)
    }

    private func deleteAccountWithTransactions(_ account: Account) async {
        do {
            // Belege der betroffenen Buchungen zuerst: Datei, dann Metadaten
            // (wie beim Einzel-Löschen, §218). Schlägt das fehl, bleibt das
            // Konto unangetastet: keine verwaisten Dateien, kein stiller Verlust.
            let transactionIDs = Set(
                try await dependencies.transactionRepository
                    .transactions(matching: TransactionQuery(accountIDs: [account.id]))
                    .map(\.id)
            )
            try await AttachmentCleanup.removeAttachments(
                of: transactionIDs,
                dependencies: dependencies,
                baseDirectory: attachmentsBaseDirectory
            )
            try await dependencies.accountRepository.deleteAccountWithTransactions(id: account.id)
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            errorMessage = String(localized: "Das Konto konnte nicht gelöscht werden.")
        }
    }

    func consentWarning(for connection: Connection, now: Date = Date()) -> String? {
        switch healthEvaluator.health(for: connection, now: now) {
        case .expired:
            return String(localized: "Zustimmung abgelaufen, bitte erneut verbinden")
        case .expiring(let days):
            return String(localized: "Zustimmung läuft in \(days) Tag(en) ab")
        case .noConsentInfo, .healthy, .blocked:
            return nil
        }
    }

    func connectionStatusLabel(for connection: Connection, now: Date = Date()) -> String {
        if let expires = connection.consentExpiresAt, expires < now {
            return String(localized: "Zustimmung abgelaufen")
        }

        if connectionDataIsStale(connection, now: now) {
            return String(localized: "Daten veraltet")
        }

        return switch connection.status {
        case .active: String(localized: "Verbunden")
        case .pendingAuthorization: String(localized: "Autorisierung offen")
        case .expired: String(localized: "Abgelaufen")
        case .revoked: String(localized: "Zugriff widerrufen")
        case .disconnected: String(localized: "Getrennt")
        }
    }

    /// Eine aktive Verbindung, deren letzter erfolgreicher Abruf länger als
    /// eine Woche zurückliegt, zeigt keinen aktuellen Stand mehr; „Verbunden"
    /// in Grün wäre dann irreführend.
    func connectionDataIsStale(_ connection: Connection, now: Date = Date()) -> Bool {
        guard connection.status == .active,
              let last = connection.lastSuccessfulSyncAt else { return false }
        return now.timeIntervalSince(last) > 7 * 24 * 60 * 60
    }

    func connectionNeedsReconnect(_ connection: Connection, now: Date = Date()) -> Bool {
        if let expires = connection.consentExpiresAt, expires < now {
            return true
        }
        return connection.status != .active
    }
}


/// A local reference distinguishes provider accounts that supply the holder's
/// name instead of a masked bank identifier. It is explicitly not an IBAN.
extension Account {
    /// Bank- oder Karten-Kennung vorhanden? Manuelle Konten (Bargeld)
    /// haben keine, die Zeile zeigt dann keine Pseudo-Referenz.
    var hasExternalIdentifier: Bool {
        if let ibanLast4, !ibanLast4.isEmpty { return true }
        if let maskedIdentifier, !maskedIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    var presentationIdentifier: String {
        if let ibanLast4, !ibanLast4.isEmpty { return "•••• " + ibanLast4 }
        if let maskedIdentifier {
            let identifier = maskedIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !identifier.isEmpty, identifier.caseInsensitiveCompare(name) != .orderedSame {
                return identifier
            }
        }
        return String(localized: "Referenz") + " " + id.uuidString.prefix(8)
    }
}

@MainActor
@Observable
final class AccountDetailModel {
    /// Wird beim Laden aus dem Repository aufgefrischt (nach „Bearbeiten").
    private(set) var account: Account
    private let dependencies: AppDependencies
    private(set) var transactions: [Transaction] = []
    private(set) var netMovement: Decimal = 0
    /// Aktueller Stand, nur bei erfasstem Anfangsbestand.
    private(set) var balance: Decimal?
    private(set) var transactionCount = 0
    private(set) var foreignCurrencies: Set<CurrencyCode> = []
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private var categoriesByID: [UUID: Category] = [:]

    init(account: Account, dependencies: AppDependencies) {
        self.account = account
        self.dependencies = dependencies
    }

    func category(for transaction: Transaction) -> Category? {
        transaction.categoryID.flatMap { categoriesByID[$0] }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            if let fresh = try await dependencies.accountRepository.account(id: account.id) {
                account = fresh
            }
            var query = TransactionQuery()
            query.accountIDs = [account.id]
            async let rowsTask = dependencies.transactionRepository.transactions(matching: query)
            async let categoriesTask = dependencies.categoryRepository.categories()
            let rows = try await rowsTask
            let categories = try await categoriesTask
            let active = rows.filter { $0.status != .reversed && $0.status != .cancelled }
            transactionCount = active.count
            let ownCurrency = active.filter { $0.amount.currency == account.currency }
            netMovement = ownCurrency.reduce(Decimal(0)) { $0 + $1.amount.amount }
            balance = AccountBalanceCalculator.balance(
                openingBalance: account.openingBalance,
                openingDate: account.openingBalanceDate,
                movements: ownCurrency.map { .init(date: $0.displayDate, amount: $0.amount.amount) }
            )
            foreignCurrencies = Set(active.map(\.amount.currency)).subtracting([account.currency])
            categoriesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
            let latest = Array(active.sorted {
                ($0.bookedAt ?? $0.createdAt) > ($1.bookedAt ?? $1.createdAt)
            }.prefix(50))
            let annotations = try await dependencies.transactionAnnotationRepository.annotations(
                transactionIDs: Set(latest.map(\.id))
            )
            transactions = EffectiveTransactionResolver().applying(annotations: annotations, to: latest)
        } catch {
            errorMessage = String(localized: "Konto-Daten konnten nicht geladen werden.")
        }
    }
}
