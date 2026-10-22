import Foundation
import os

struct BankSyncResult: Sendable {
    let connectionID: UUID
    let accountsSynced: Int
    let importedCount: Int
    let updatedCount: Int
    let duplicateCount: Int
    /// Ältestes Buchungsdatum, das die Bank bei diesem Abruf geliefert hat.
    var earliestBookingDate: Date?
}

/// Bank-Sync ohne MainActor-Bindung: Fetch-Loop + Commit
/// laufen im Hintergrund (nonisolated + Task.detached); nur UI-relevante
/// State-Updates (DataChangeTracker) hüpfen auf den MainActor.
struct BankSyncService: Sendable {
    /// Console.app-Filter für einen echten Banklauf: subsystem
    /// de.klabautter.FinanceTracker, category "banking". Es werden nur
    /// Zähler, Status und gekürzte Kennungen protokolliert.
    static let logger = Logger(subsystem: "de.klabautter.FinanceTracker", category: "banking")

    private let dependencies: AppDependencies
    private let provider: any BankDataProvider

    init(dependencies: AppDependencies, provider: any BankDataProvider) {
        self.dependencies = dependencies
        self.provider = provider
    }

    func connect(
        institution: BankInstitution,
        providerConnectionID: String,
        linkedAccountIDs: [String],
        providerRaw: ConnectionProvider = .gocardless,
        consentDays: Int? = nil,
        consentExpiresAt: Date? = nil
    ) async throws -> Connection {
        let now = Date()
        let connection = Connection(
            id: UUID(),
            userID: UUID(),
            provider: providerRaw,
            providerConnectionID: providerConnectionID,
            institutionID: institution.id,
            status: .active,
            consentExpiresAt: consentExpiresAt ?? consentDays.flatMap { Calendar.current.date(byAdding: .day, value: $0, to: now) },
            lastSuccessfulSyncAt: nil,
            createdAt: now,
            updatedAt: now,
            institutionName: institution.name
        )

        try await dependencies.connectionRepository.upsert([connection])
        await MainActor.run { dependencies.changeTracker.markChanged() }
        return connection
    }

    func ensureBankAccount(
        remote: RemoteBankAccount,
        connection: Connection,
        fallbackName: String
    ) async throws -> Account {
        guard let remoteProviderAccountID = remote.providerAccountID else {
            throw ImportError.parsingFailed(stage: "bankSync", reason: String(localized: "Remote-Konto ohne Provider-Account-ID."))
        }

        // Dedup innerhalb derselben Verbindung, auch für Konten, die noch
        // unter der sitzungsgebundenen ID (`remote.id`) gespeichert sind; sie
        // bekommen dabei die stabile Kennung.
        for candidateID in Set([remoteProviderAccountID, remote.id]) {
            guard var existing = try await dependencies.accountRepository.account(
                providerAccountID: candidateID,
                connectionID: connection.id
            ) else { continue }
            var changed = false
            if existing.providerAccountID != remoteProviderAccountID {
                existing.providerAccountID = remoteProviderAccountID
                changed = true
            }
            if Self.hasAutomaticName(existing, remote: remote), existing.name != fallbackName {
                existing.name = fallbackName
                changed = true
            }
            if changed {
                try await dependencies.accountRepository.upsert([existing])
            }
            return existing
        }

        // WP-MacUX (doppelte Konten nach Re-Connect): Jede (Wieder-)
        // Verbindung erhält eine neue Connection-ID: das KONTO darf
        // trotzdem nur einmal pro Provider-Konto existieren. Existiert es
        // unter einer früheren Verbindung, wird es auf die neue Verbindung
        // umgehängt statt dupliziert (Dedup über Source +
        // Provider-ID, als Fingerprint-Fallback masked IBAN + Währung).
        let existingAccounts = try await dependencies.accountRepository.accounts()
        let ibanFingerprint = Self.ibanFingerprint(of: remote)
        if let relink = existingAccounts.first(where: { account in
            guard account.source == .openBanking else { return false }
            if account.providerAccountID == remoteProviderAccountID { return true }
            if account.providerAccountID == remote.id { return true }
            guard let ibanFingerprint, !ibanFingerprint.isEmpty else { return false }
            return account.currency == remote.currency && account.ibanLast4 == ibanFingerprint
        }) {
            var relinked = relink
            relinked.providerAccountID = remoteProviderAccountID
            relinked.connectionID = connection.id
            relinked.institutionID = connection.institutionID
            relinked.isActive = true
            // MacUX-Audit #5: Alte, unbrauchbare „Bankkonto"-Fallback-Namen
            // werden beim Sync mit dem besseren Namen ersetzt.
            if Self.hasAutomaticName(relinked, remote: remote) {
                relinked.name = fallbackName
            }
            try await dependencies.accountRepository.upsert([relinked])
            await MainActor.run { dependencies.changeTracker.markChanged() }
            return relinked
        }

        var masked = remote.maskedIBAN
        if masked == nil, let rawOwner = remote.ownerName { masked = rawOwner }
        let account = Account(
            id: UUID(),
            connectionID: connection.id,
            institutionID: connection.institutionID,
            name: fallbackName,
            type: .checking,
            currency: remote.currency,
            maskedIdentifier: masked ?? "••••",
            ibanLast4: (remote.maskedIBAN ?? "").suffix(4).isEmpty ? nil : String((remote.maskedIBAN ?? "").suffix(4)),
            providerAccountID: remoteProviderAccountID,
            source: .openBanking
        )
        try await dependencies.accountRepository.upsert([account])
        await MainActor.run { dependencies.changeTracker.markChanged() }
        return account
    }

    static func defaultAccountName(bankName: String?, remote: RemoteBankAccount, sharesConnection: Bool) -> String {
        let last4 = String((remote.maskedIBAN ?? "").suffix(4)).trimmingCharacters(in: .whitespaces)
        if let bankName, !bankName.isEmpty {
            return sharesConnection && !last4.isEmpty ? "\(bankName) ••\(last4)" : bankName
        }
        if let owner = remote.ownerName, !owner.isEmpty { return owner }
        if let providerID = remote.providerAccountID, providerID.count >= 4 {
            return "Konto ••\(String(providerID.suffix(4)))"
        }
        return "Konto \(remote.id.suffix(4))"
    }

    /// Vom Nutzer umbenannte Konten bleiben unangetastet; ersetzt werden nur
    /// die früheren Automatik-Namen (Kontoinhaber, „Bankkonto …").
    static func hasAutomaticName(_ account: Account, remote: RemoteBankAccount) -> Bool {
        if account.name.hasPrefix("Bankkonto") { return true }
        if let owner = remote.ownerName, !owner.isEmpty, account.name == owner { return true }
        return false
    }

    /// Fingerprint aus der maskierten IBAN (gleiche Ableitung wie bei der
    /// Konto-Anlage), damit Session-übergreifende Provider-Account-IDs
    /// trotzdem dedupliziert werden können.
    private static func ibanFingerprint(of remote: RemoteBankAccount) -> String? {
        let suffix = String((remote.maskedIBAN ?? "").suffix(4))
        return suffix.isEmpty ? nil : suffix
    }

    /// - Parameter historyStart: Ausdrücklich angefragter Beginn der Umsätze
    ///   (z. B. „ein Jahr zurück“ beim Verbinden). Ohne Angabe: seit dem
    ///   letzten Abruf mit Überlappung, beim ersten Abruf der Bank-Standard.
    func sync(connection: Connection, historyStart: Date? = nil) async throws -> BankSyncResult {
        guard let providerConnectionID = connection.providerConnectionID else {
            throw BankProviderError.missingCredentials
        }

        let state: RemoteConnectionState
        do {
            state = try await provider.connectionStatus(connectionID: providerConnectionID)
        } catch {
            Self.logger.error("Sync \(Self.short(connection.id), privacy: .public): Session-Status fehlgeschlagen: \(Self.describe(error), privacy: .public)")
            throw error
        }
        Self.logger.info("Sync \(Self.short(connection.id), privacy: .public): Status \(String(describing: state.authorization), privacy: .public), \(state.linkedAccountIDs.count, privacy: .public) Konten, Zustimmung bis \(state.consentValidUntil.map { AppDateFormatter.day($0) } ?? "unbekannt", privacy: .public)")
        guard state.authorization == .ready else {
            throw ImportError.unsupportedFormat(reason: ImportError.connectionNotAuthorizedReason)
        }
        let pipeline = ImportPipeline(
            providers: [],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            merchantRepository: dependencies.merchantRepository,
            categoryRepository: dependencies.categoryRepository,
            fallbackCurrency: dependencies.baseCurrency
        )

        var totalImported = 0
        var totalUpdated = 0
        var totalDuplicates = 0
        var syncedAccounts = 0

        // Fetch-Loop + Mapping + Commit laufen im Hintergrund
        // (Task.detached). Alle Captures sind Sendable (Connection,
        // ImportPipeline, Provider; AppDependencies ist @unchecked Sendable).
        // UI-relevante Updates (changeTracker, Connection-Upsert) bleiben
        // außerhalb bzw. hüpfen auf den MainActor.
        let backgroundDependencies = dependencies
        let backgroundProvider = provider
        let connectionSnapshot = connection
        let calendar = Calendar.current
        let totals = try await Task.detached(priority: .userInitiated) {
            var imported = 0
            var updated = 0
            var duplicates = 0
            var synced = 0
            var syncedAccountIDs: [UUID] = []
            var earliest: Date?
            let backgroundService = BankSyncService(
                dependencies: backgroundDependencies,
                provider: backgroundProvider
            )
            for remoteAccountID in state.linkedAccountIDs {
                let overlapStart = historyStart ?? connectionSnapshot.lastSuccessfulSyncAt.flatMap {
                    calendar.date(byAdding: .day, value: -7, to: $0)
                }
                let data: RemoteBankAccountData
                do {
                    data = try await backgroundProvider.fetchAccountData(accountID: remoteAccountID, dateFrom: overlapStart)
                } catch {
                    Self.logger.error("Sync \(Self.short(connectionSnapshot.id), privacy: .public): Konto …\(remoteAccountID.suffix(4), privacy: .public) Abruf fehlgeschlagen: \(Self.describe(error), privacy: .public)")
                    throw error
                }
                Self.logger.info("Sync \(Self.short(connectionSnapshot.id), privacy: .public): Konto …\(remoteAccountID.suffix(4), privacy: .public) \(data.account.currency.rawValue, privacy: .public), \(data.transactions.count, privacy: .public) Umsätze ab \(overlapStart.map { AppDateFormatter.day($0) } ?? "Anfang", privacy: .public)")

                guard !data.account.id.isEmpty else {
                    throw ImportError.parsingFailed(stage: "bankSync", reason: String(localized: "Konto \(remoteAccountID) lieferte keine Details."))
                }

                // Konten heißen nach ihrer Bank („DKB"), bei mehreren Konten
                // derselben Verbindung mit IBAN-Ende. Ohne Banknamen wie bisher
                // der Kontoinhaber, sonst das Kennungs-Ende.
                let bankName = connectionSnapshot.institutionName
                    ?? connectionSnapshot.institutionID.flatMap { backgroundProvider.institutionDisplayName(forInstitutionID: $0) }
                let fallbackName = Self.defaultAccountName(
                    bankName: bankName,
                    remote: data.account,
                    sharesConnection: state.linkedAccountIDs.count > 1
                )
                let account = try await backgroundService.ensureBankAccount(
                    remote: data.account,
                    connection: connectionSnapshot,
                    fallbackName: fallbackName
                )

                if let accountEarliest = data.transactions.compactMap(\.bookingDate).min() {
                    earliest = min(earliest ?? accountEarliest, accountEarliest)
                }
                if backgroundProvider.identifier == ConnectionProvider.enablebanking.rawValue {
                    // Alte, sitzungsgebundene Buchungs-IDs vor dem Abgleich umstellen.
                    try await EnableBankingExternalIDMigration(
                        transactionRepository: backgroundDependencies.transactionRepository
                    ).run(accountIDs: [account.id])
                }
                let ownerNames = [data.account.ownerName].compactMap { $0 }.filter { !$0.isEmpty }
                let importedTxns: [ImportedTransaction] = data.transactions.compactMap { remoteTxn in
                    // Händler ist die Gegenseite, bei Gutschriften der Absender,
                    // nicht der Kontoinhaber selbst.
                    let counterparty = remoteTxn.counterparty
                    let merchantRaw = counterparty.name ?? remoteTxn.remittanceInformation
                    let counterpartyClass = CounterpartyClassifier.classify(
                        counterparty,
                        rawDescription: remoteTxn.remittanceInformation,
                        ownerNames: ownerNames
                    )
                    let status: TransactionStatus = remoteTxn.state == .pending ? .pending : .booked

                    return ImportedTransaction(
                        externalID: remoteTxn.externalID,
                        status: status,
                        kind: .unknown,
                        amount: Money(amount: remoteTxn.amount.amount, currency: remoteTxn.amount.currency),
                        bookedAt: remoteTxn.bookingDate,
                        authorizedAt: remoteTxn.state == .pending ? (remoteTxn.valueDate ?? remoteTxn.bookingDate) : nil,
                        rawDescription: remoteTxn.remittanceInformation ?? merchantRaw,
                        rawMerchantName: merchantRaw,
                        merchantDisplayName: merchantRaw,
                        counterpartyClass: counterpartyClass,
                        counterpartyLabel: counterpartyClass.map {
                            CounterpartyClassifier.displayName(
                                for: $0,
                                counterparty: counterparty,
                                rawDescription: remoteTxn.remittanceInformation
                            )
                        }
                    )
                }

                let result = try await pipeline.commitParsedTransactions(
                    importedTxns,
                    source: .openBanking,
                    providerIdentifier: backgroundProvider.identifier,
                    into: account.id
                )

                try await backgroundService.classifyEarlierTransfers(accountID: account.id, ownerNames: ownerNames)

                imported += result.importedCount
                updated += result.updatedCount
                duplicates += result.duplicateCount
                synced += 1
                syncedAccountIDs.append(account.id)
            }
            return (imported, updated, duplicates, synced, syncedAccountIDs, earliest)
        }.value
        totalImported = totals.0
        totalUpdated = totals.1
        totalDuplicates = totals.2
        syncedAccounts = totals.3

        var updatedConnection = connection
        updatedConnection.status = .active
        // Verbindungen von vor der Namensspeicherung bekommen ihren Banknamen.
        if updatedConnection.institutionName == nil, let institutionID = updatedConnection.institutionID {
            updatedConnection.institutionName = provider.institutionDisplayName(forInstitutionID: institutionID)
        }
        updatedConnection.lastSuccessfulSyncAt = Date()
        updatedConnection.updatedAt = Date()
        // Tatsächliches Zustimmungs-Ende vom Provider übernehmen, damit die
        // Ablauf-Warnung (T-10 Tage) vor der nötigen Re-Autorisierung greift.
        if let validUntil = state.consentValidUntil {
            updatedConnection.consentExpiresAt = validUntil
        }
        try await dependencies.connectionRepository.upsert([updatedConnection])
        await mirrorCashWithdrawals(accountIDs: totals.4, since: connection.lastSuccessfulSyncAt.flatMap {
            calendar.date(byAdding: .day, value: -7, to: $0)
        })
        await MainActor.run { dependencies.changeTracker.markChanged() }
        Self.logger.info("Sync \(Self.short(connection.id), privacy: .public) fertig: \(syncedAccounts, privacy: .public) Konten, \(totalImported, privacy: .public) neu, \(totalUpdated, privacy: .public) aktualisiert, \(totalDuplicates, privacy: .public) Duplikate")

        return BankSyncResult(
            connectionID: connection.id,
            accountsSynced: syncedAccounts,
            importedCount: totalImported,
            updatedCount: totalUpdated,
            duplicateCount: totalDuplicates,
            earliestBookingDate: totals.5
        )
    }

    /// Ältere, noch offene Belastungen nachträglich einordnen: Umbuchungen
    /// aufs eigene Konto und Einzahlungen beim Broker. Sie zählen weiter als
    /// Ausgabe, bis die Gegenbuchung in der App ist (`LinkOwnTransfers`). Nur Belastungen:
    /// bei früher geladenen Gutschriften stand noch der Kontoinhaber statt
    /// des Absenders als Gegenseite. Vergebene Kategorien bleiben.
    func classifyEarlierTransfers(accountID: UUID, ownerNames: [String]) async throws {
        var query = TransactionQuery()
        query.accountIDs = [accountID]
        query.sources = [.openBanking]
        let transactions = try await dependencies.transactionRepository.transactions(matching: query)
        guard !transactions.isEmpty else { return }

        let categories = try await dependencies.categoryRepository.categories()
        let assignable = Set(CategoryHierarchy().assignableCategories(in: categories).map(\.id))
        var updates: [Transaction] = []
        for transaction in transactions {
            let counterparty = Counterparty(name: transaction.rawMerchantName)
            if transaction.categoryID == nil, transaction.amount.isNegative {
                guard let match = CounterpartyClassifier.classify(
                    counterparty,
                    rawDescription: transaction.rawDescription,
                    ownerNames: ownerNames
                ), assignable.contains(match.categoryID) else { continue }
                var updated = transaction
                updated.categoryID = match.categoryID
                updated.merchantDisplayName = CounterpartyClassifier.displayName(
                    for: match, counterparty: counterparty, rawDescription: transaction.rawDescription
                )
                updated.merchantID = nil
                updated.updatedAt = Date()
                updates.append(updated)
            } else if [Category.transfers.id, Category.investments.id].contains(transaction.categoryID),
                      ownerNames.contains(where: { CounterpartyClassifier.isSamePerson(transaction.effectiveMerchantName, $0) }) {
                // Früher eingeordnet, aber noch mit dem eigenen Namen als
                // Händler: lesbaren Namen nachziehen („Trade Republic").
                let kind: CounterpartyClass = transaction.categoryID == Category.investments.id ? .broker : .ownAccount
                var updated = transaction
                updated.merchantDisplayName = CounterpartyClassifier.displayName(
                    for: kind, counterparty: counterparty, rawDescription: transaction.rawDescription
                )
                updated.merchantID = nil
                updated.updatedAt = Date()
                updates.append(updated)
            }
        }
        guard !updates.isEmpty else { return }
        try await dependencies.transactionRepository.upsert(updates)
        try await LinkOwnTransfers(transactionRepository: dependencies.transactionRepository).run()
        Self.logger.info("Sync: \(updates.count, privacy: .public) frühere Überweisungen eingeordnet")
    }

    /// Bargeld-Automatik: erkannte Abhebungen im Sync-Fenster ins
    /// eingestellte Bargeldkonto spiegeln. Fehler brechen den Sync nicht ab.
    private func mirrorCashWithdrawals(accountIDs: [UUID], since: Date?) async {
        guard dependencies.preferences.cashWithdrawalTargetAccountID != nil, !accountIDs.isEmpty else { return }
        do {
            var query = TransactionQuery()
            query.accountIDs = Set(accountIDs)
            if let since {
                query.dateInterval = DateInterval(start: since, end: Date.distantFuture)
            }
            let candidates = try await dependencies.transactionRepository.transactions(matching: query)
            let created = try await MirrorCashWithdrawal(dependencies: dependencies).mirrorDetectedWithdrawals(in: candidates)
            if created > 0 {
                Self.logger.info("Bargeld-Automatik: \(created, privacy: .public) Abhebungen gutgeschrieben")
            }
        } catch {
            Self.logger.error("Bargeld-Automatik fehlgeschlagen: \(Self.describe(error), privacy: .public)")
        }
    }

    // MARK: - Logging-Helfer (keine Secrets, keine vollständigen Kennungen)

    private static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    static func describe(_ error: Error) -> String {
        if case BankProviderError.requestFailed(let endpoint, let status, _) = error {
            return "HTTP \(status) bei \(endpoint)"
        }
        if case BankProviderError.invalidResponse(let endpoint) = error {
            return "unlesbare Antwort bei \(endpoint)"
        }
        if case BankProviderError.missingCredentials = error {
            return "keine Zugangsdaten"
        }
        return String(describing: type(of: error))
    }
}
