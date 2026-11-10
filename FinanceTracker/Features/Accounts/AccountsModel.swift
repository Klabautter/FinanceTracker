import Foundation

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
    /// Gesamtstand über alle aktiven Konten mit bekanntem Stand.
    private(set) var liquidity: LiquidityOverview?
    /// Laden (AGENTS #37); Speicher-, Lösch- und Eingabefehler stehen
    /// getrennt in `actionError`.
    private(set) var loadState: LoadState = .idle
    private(set) var actionError: String?
    var isLoading: Bool { loadState.isLoading }

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
        loadState = .loading
        var failure: String?
        defer {
            loadState = failure.map { .failed($0) } ?? .loaded
            PerfSignpost.signposter.endInterval("AccountsLoad", signpost)
        }

        do {
            let converter = await dependencies.fxRateProvider.converter()
            async let balancesTask = LoadAccountBalances(
                accountRepository: dependencies.accountRepository,
                transactionRepository: dependencies.transactionRepository
            ).execute(converter: converter)
            async let connectionsTask = dependencies.connectionRepository.connections()
            let balances = try await balancesTask
            let fetchedConnections = try await connectionsTask
            connections = await namedConnections(fetchedConnections).sorted { $0.updatedAt > $1.updatedAt }
            // Deaktivierte Konten (z. B. nach „Verbindung trennen" oder
            // Re-Connect-Dedup) stehen nicht zwischen den aktiven Konten,
            // sondern in einem eigenen Abschnitt „Getrennte Konten".
            accounts = balances.active
            disconnectedAccounts = balances.inactive
            let overview = LiquidityCalculator(
                baseCurrency: dependencies.baseCurrency,
                converter: converter
            ).overview(of: balances.active)
            liquidity = overview.shares.isEmpty ? nil : overview
        } catch {
            failure = String(localized: "Die Konten konnten nicht geladen werden.")
        }
    }

    func sync(connection: Connection) async -> String? {
        do {
            // Über den Koordinator: Provider-Routing nach
            // Connection.provider, und nie zwei Abrufe gleichzeitig (z. B.
            // Klick während des automatischen Abrufs).
            let result = try await dependencies.bankSyncCoordinator.sync(connection, dependencies: dependencies)
            dependencies.changeTracker.markChanged()
            await load()
            return String(localized: "Sync fertig: \(result.importedCount) neu, \(result.updatedCount) aktualisiert.")
        } catch let error as BankProviderError {
            actionError = String(localized: "Sync fehlgeschlagen: \(Self.providerFailureMessage(for: error))")
            return nil
        } catch {
            actionError = String(localized: "Sync fehlgeschlagen: \(error.localizedDescription)")
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
            actionError = String(localized: "Verbindung konnte nicht getrennt werden.")
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
            actionError = String(localized: "Das Konto konnte nicht gelöscht werden.")
        }
    }

    /// „Stand festlegen" aus der Kontenliste: Der genannte Stand gilt am
    /// Ende des Tages `date`; gespeichert wird der passende Anfangsbestand.
    func setBalance(_ balance: Decimal, for account: Account, on date: Date = Date()) async {
        do {
            try await SetAccountBalance(
                accountRepository: dependencies.accountRepository,
                transactionRepository: dependencies.transactionRepository
            )(balance, for: account, on: date)
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            actionError = String(localized: "Der Kontostand konnte nicht gespeichert werden.")
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
        ConnectionStatusPresentation.label(
            for: connection,
            health: healthEvaluator.health(for: connection, now: now),
            now: now
        )
    }

    /// Eine aktive Verbindung ohne erfolgreichen Abruf seit einer Woche.
    func connectionDataIsStale(_ connection: Connection, now: Date = Date()) -> Bool {
        ConnectionStatusPresentation.isStale(connection, now: now)
    }

    func connectionNeedsReconnect(_ connection: Connection, now: Date = Date()) -> Bool {
        ConnectionStatusPresentation.needsReconnect(connection, health: healthEvaluator.health(for: connection, now: now), now: now)
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
    /// Aktueller Stand wie in der Kontenliste: gemeldeter Stand (Bank oder
    /// Kontoauszug) vor Anfangsbestand; ohne beides `nil`.
    private(set) var balanceResult: AccountBalanceCalculator.Result?
    var balance: Decimal? { balanceResult?.amount }
    private(set) var transactionCount = 0
    private(set) var foreignCurrencies: Set<CurrencyCode> = []
    /// Beginnt ladend, damit das Detail nie kurz leer aufblitzt (AGENTS #37).
    private(set) var loadState: LoadState = .loading
    var isLoading: Bool { loadState.isLoading }
    private var categoriesByID: [UUID: Category] = [:]

    init(account: Account, dependencies: AppDependencies) {
        self.account = account
        self.dependencies = dependencies
    }

    func category(for transaction: Transaction) -> Category? {
        transaction.categoryID.flatMap { categoriesByID[$0] }
    }

    func load() async {
        loadState = .loading
        var failure: String?
        defer { loadState = failure.map { .failed($0) } ?? .loaded }
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
            let active = rows.filter { $0.status.isEffective }
            transactionCount = active.count
            let ownCurrency = active.filter { $0.amount.currency == account.currency }
            netMovement = ownCurrency.reduce(Decimal(0)) { $0 + $1.amount.amount }
            balanceResult = AccountBalanceCalculator.balance(
                for: account,
                movements: ownCurrency.map { .init(date: $0.displayDate, amount: $0.amount.amount) },
                converter: await dependencies.fxRateProvider.converter()
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
            failure = String(localized: "Konto-Daten konnten nicht geladen werden.")
        }
    }
}
