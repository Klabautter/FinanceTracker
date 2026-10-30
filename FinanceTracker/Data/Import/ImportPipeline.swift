import CryptoKit
import Foundation

struct ImportResult: Sendable, Equatable {
    let providerIdentifier: String
    let totalRows: Int
    let importedCount: Int
    let updatedCount: Int
    let duplicateCount: Int
    let failedCount: Int
    /// FileHash-Frühwarnung (#1): exakt gleiche Datei wurde schon importiert.
    /// Zählung bleibt row-level (kein Doppelzählen, kein stilles Verwerfen).
    var isExactFileReplay: Bool = false
    /// Cross-Source-Prüfhinweise (Warnungen, keine Fehler): gleiche reale
    /// Buchung aus anderer Quelle. Zählt NICHT als Duplikat/Fehler (#18).
    var crossSourceHintCount: Int = 0
    /// Zeilen, die auf dem Konto schon aus einer anderen Quelle vorliegen
    /// (z. B. PDF-Auszug und CSV-Export derselben Karte) und deshalb nicht
    /// importiert wurden. Gezählt und sichtbar, nicht still verworfen.
    var crossSourceDuplicateCount: Int = 0

    /// UI-Label für Duplikate, bewusst identisch mit der ImportView-Preview
    /// („Duplikate übersprungen: N"), damit Summary + Preview konsistent bleiben (#5).
    static var duplicateLabel: String { String(localized: "Duplikate übersprungen") }

    var summaryMessage: String {
        var parts = [String(localized: "Importiert: \(importedCount)")]
        if updatedCount > 0 {
            parts.append(String(localized: "Aktualisiert (Pending→Booked): \(updatedCount)"))
        }
        if duplicateCount > 0 {
            parts.append("\(Self.duplicateLabel): \(duplicateCount)")
        }
        if failedCount > 0 {
            parts.append(String(localized: "Fehlgeschlagen: \(failedCount)"))
        }
        if crossSourceDuplicateCount > 0 {
            parts.append(String(localized: "Bereits vorhanden (andere Quelle): \(crossSourceDuplicateCount)"))
        }
        if crossSourceHintCount > 0 {
            parts.append(String(localized: "Prüfhinweise (andere Quelle): \(crossSourceHintCount)"))
        }
        if isExactFileReplay {
            parts.append(ImportDedupNotices.fileAlreadyImported)
        }
        return parts.joined(separator: " · ")
    }
}

/// Zentrale UI-Hinweistexte für Dedup-Edge-Cases (keine Business-Logik
/// in Views: Views zeigen nur diese Strings an).
enum ImportDedupNotices: Sendable {
    /// FileHash-Frühwarnung: exakter Datei-Replay.
    static var fileAlreadyImported: String { String(localized: "Datei wurde bereits importiert") }
    static var fileReplayDetail: String {
        String(localized: "Datei wurde bereits importiert. Zeilen werden erneut als Duplikate geprüft, es wird nichts doppelt gezählt.")
    }
    /// Konto-scharfer Fingerprint: gleiche Zeilen auf einem
    /// anderen Konto sind bewusst KEINE Duplikate.
    static var differentAccountHint: String {
        String(localized: "Gleiche Zeilen auf einem anderen Konto werden bewusst nicht als Duplikate gewertet (konto-scharfer Fingerprint aus Konto, Quelle, Währung und Betrag/Text).")
    }
    /// Cross-Source-Hinweis (CSV vs. openBanking): kein stilles Mergen (#18),
    /// nur Review-Kandidat.
    static var crossSourceHintPrefix: String { String(localized: "Mögliche Doppelbuchung aus anderer Quelle") }
}

private struct ExternalTransactionKey: Hashable, Sendable {
    let accountID: UUID
    let source: TransactionSource
    let currency: CurrencyCode
    let externalID: String
}

struct PreparedImport: Sendable, Equatable {
    let targetAccountID: UUID
    let providerIdentifier: String
    let totalRows: Int
    let transactions: [Transaction]
    let updates: [Transaction]
    let duplicateCount: Int
    let failedCount: Int
    var issues: [ImportRowIssue] = []
    var mutations: [ImportMutation] = []
    var newMerchants: [Merchant] = []
    var batch: ImportBatch?
    /// FileHash-Frühwarnung (#1): exakt gleiche Datei (gleicher Hash) wurde
    /// schon importiert. Preview zeigt den Hinweis, Zählung bleibt row-level.
    var isExactFileReplay: Bool = false
    /// Prüfhinweise: Zeilen, die trotz vorhandener Buchung aus anderer
    /// Quelle importiert werden (Bankabruf oder „Trotzdem importieren“).
    var crossSourceHints: [ImportRowIssue] = []
    /// Zeilen, die schon aus einer anderen Quelle auf dem Konto liegen und
    /// übersprungen werden (je Zeile ein Hinweis mit der vorhandenen Quelle).
    var crossSourceDuplicates: [ImportRowIssue] = []

    var fileReplayNotice: String? {
        isExactFileReplay ? ImportDedupNotices.fileReplayDetail : nil
    }

    var importResultPreview: ImportResult {
        ImportResult(
            providerIdentifier: providerIdentifier,
            totalRows: totalRows,
            importedCount: transactions.count,
            updatedCount: updates.count,
            duplicateCount: duplicateCount,
            failedCount: failedCount,
            isExactFileReplay: isExactFileReplay,
            crossSourceHintCount: crossSourceHints.count,
            crossSourceDuplicateCount: crossSourceDuplicates.count
        )
    }
}

struct ImportPipeline: Sendable {
    private let providers: [any ImportProvider]
    private let transactionRepository: any TransactionRepository
    private let ruleRepository: (any CategoryRuleRepository)?
    private let importBatchRepository: (any ImportBatchRepository)?
    private let merchantRepository: (any MerchantRepository)?
    private let categoryRepository: (any CategoryRepository)?
    private let fallbackCurrency: CurrencyCode

    init(
        providers: [any ImportProvider],
        transactionRepository: any TransactionRepository,
        ruleRepository: (any CategoryRuleRepository)? = nil,
        importBatchRepository: (any ImportBatchRepository)? = nil,
        merchantRepository: (any MerchantRepository)? = nil,
        categoryRepository: (any CategoryRepository)? = nil,
        fallbackCurrency: CurrencyCode
    ) {
        self.providers = providers
        self.transactionRepository = transactionRepository
        self.ruleRepository = ruleRepository
        self.importBatchRepository = importBatchRepository
        self.merchantRepository = merchantRepository
        self.categoryRepository = categoryRepository
        self.fallbackCurrency = fallbackCurrency
    }

    func run(
        _ file: ImportFile,
        into accountID: UUID,
        preferredProviderIdentifier: String? = nil
    ) async throws -> ImportResult {
        let prepared = try await prepare(file, into: accountID, preferredProviderIdentifier: preferredProviderIdentifier)
        return try await commit(prepared)
    }

    @discardableResult
    func commitParsedTransactions(
        _ importedTransactions: [ImportedTransaction],
        source: TransactionSource,
        providerIdentifier: String,
        into accountID: UUID
    ) async throws -> ImportResult {
        var query = TransactionQuery()
        query.accountIDs = [accountID]
        query.sources = [source]

        let existing = try await transactionRepository.transactions(matching: query)
        var existingByFingerprint: [String: Transaction] = [:]
        for txn in existing {
            guard let fp = txn.sourceFingerprint else { continue }
            if existingByFingerprint[fp] == nil {
                existingByFingerprint[fp] = txn
            }
        }
        let existingExternalIDs = Set(existing.compactMap { txn -> ExternalTransactionKey? in
            guard let externalID = txn.externalID else { return nil }
            return Self.externalKey(
                accountID: txn.accountID,
                source: txn.source,
                currency: txn.amount.currency,
                externalID: externalID
            )
        })
        var existingByExternalKey: [ExternalTransactionKey: Transaction] = [:]
        for txn in existing {
            guard let externalID = txn.externalID else { continue }
            let key = Self.externalKey(
                accountID: txn.accountID,
                source: txn.source,
                currency: txn.amount.currency,
                externalID: externalID
            )
            if existingByExternalKey[key] == nil { existingByExternalKey[key] = txn }
        }
        let pendingCandidates = existing.filter { $0.status == .pending }

        // Cross-Source-Hinweis (kein stilles Mergen): gleiche reale
        // Buchung aus anderer Quelle (gleicher Account/Tag/Betrag/Text) wird NICHT
        // als Duplikat gewertet. Stattdessen wird ein Review-Kandidat markiert,
        // die Zeile wird trotzdem importiert (heutiges Verhalten: 2 Einträge).
        // ReviewQueue-Anbindung (Vorschlag): `ReviewItem.Reason` um
        // `.possibleCrossSourceDuplicate` erweitern und `crossSourceHints` in
        // `ReviewQueueBuilder.buildItems` einspeisen.
        var accountQuery = TransactionQuery()
        accountQuery.accountIDs = [accountID]
        let accountWideExisting = try await transactionRepository.transactions(matching: accountQuery)
        let crossSourceIndex = Self.crossSourceIndex(from: accountWideExisting, excludingSource: source)

        let rules: [CategoryRule]
        if let ruleRepository {
            rules = try await ruleRepository.rules()
        } else {
            rules = []
        }
        let assignableCategoryIDs = try await loadAssignableCategoryIDs()
        let compiledCategoryRules = CategoryRuleEngine().compile(
            rules,
            assignableCategoryIDs: assignableCategoryIDs
        )
        var knownMerchants = try await merchantRepository?.merchants() ?? []
        var merchantUpserts: [Merchant.ID: Merchant] = [:]
        let reconciler = PendingBookedReconciler()
        var availableCandidates = pendingCandidates

        var seenFingerprints = Set<String>()
        var seenExternalKeys = Set<ExternalTransactionKey>()
        var inserts: [Transaction] = []
        var updates: [Transaction] = []
        var mutations: [ImportMutation] = []
        var crossSourceHints: [ImportRowIssue] = []
        var duplicateCount = 0

        let startedAt = Date()
        let batchID = UUID()
        let fileHash = ImportBatch.fileHash(of: Data("\(batchID.uuidString)|\(importedTransactions.count)".utf8))

        var occurrencesByBaseFingerprint: [String: Int] = [:]
        for (rowOffset, imported) in importedTransactions.enumerated() {
            let bookingDate = imported.bookedAt ?? imported.authorizedAt
            let baseFingerprint = TransactionFingerprinter.fingerprint(
                source: source,
                accountID: accountID,
                bookingDate: bookingDate,
                amount: imported.amount,
                merchantOrDescription: imported.rawMerchantName ?? imported.rawDescription ?? "",
                balanceAfter: imported.balanceAfter
            )
            let occurrence = (occurrencesByBaseFingerprint[baseFingerprint] ?? 0) + 1
            occurrencesByBaseFingerprint[baseFingerprint] = occurrence
            let fingerprint = occurrence == 1 ? baseFingerprint : TransactionFingerprinter.fingerprint(
                source: source,
                accountID: accountID,
                bookingDate: bookingDate,
                amount: imported.amount,
                merchantOrDescription: imported.rawMerchantName ?? imported.rawDescription ?? "",
                balanceAfter: imported.balanceAfter,
                occurrence: occurrence
            )

            var draft = Self.makeTransaction(
                from: imported,
                source: source,
                accountID: accountID,
                fingerprint: fingerprint
            )
            normalizeAndCategorize(
                &draft,
                rawDescriptor: imported.rawMerchantName ?? imported.rawDescription ?? imported.merchantDisplayName,
                knownMerchants: &knownMerchants,
                merchantUpserts: &merchantUpserts,
                categoryRules: compiledCategoryRules,
                suggestedCategoryID: imported.suggestedCategoryID,
                counterpartyClass: imported.counterpartyClass,
                counterpartyLabel: imported.counterpartyLabel,
                assignableCategoryIDs: assignableCategoryIDs
            )

            if let exact = existingByFingerprint[fingerprint] {
                if exact.status == .pending && imported.status != .pending {
                    mutations.append(ImportMutation(
                        transactionID: exact.id,
                        kind: .updated,
                        previousSnapshot: TransactionSnapshot(transaction: exact)
                    ))
                    updates.append(Self.merged(target: exact, with: draft))
                    availableCandidates.removeAll { $0.id == exact.id }
                } else {
                    duplicateCount += 1
                }
                continue
            }

            if let externalID = imported.externalID {
                let key = Self.externalKey(
                    accountID: accountID,
                    source: source,
                    currency: imported.amount.currency,
                    externalID: externalID
                )
                if existingExternalIDs.contains(key) || !seenExternalKeys.insert(key).inserted {
                    if let target = reconciler.findTarget(for: draft, among: availableCandidates) {
                        mutations.append(ImportMutation(
                            transactionID: target.id,
                            kind: .updated,
                            previousSnapshot: TransactionSnapshot(transaction: target)
                        ))
                        updates.append(Self.merged(target: target, with: draft))
                        availableCandidates.removeAll { $0.id == target.id }
                    } else if let existingTransaction = existingByExternalKey[key],
                              let refreshed = Self.refreshedCounterparty(target: existingTransaction, with: draft) {
                        mutations.append(ImportMutation(
                            transactionID: existingTransaction.id,
                            kind: .updated,
                            previousSnapshot: TransactionSnapshot(transaction: existingTransaction)
                        ))
                        updates.append(refreshed)
                        existingByExternalKey[key] = refreshed
                    } else {
                        duplicateCount += 1
                    }
                    continue
                }
            }

            if !seenFingerprints.insert(fingerprint).inserted {
                duplicateCount += 1
                continue
            }

            if let target = reconciler.findTarget(for: draft, among: availableCandidates) {
                mutations.append(ImportMutation(
                    transactionID: target.id,
                    kind: .updated,
                    previousSnapshot: TransactionSnapshot(transaction: target)
                ))
                updates.append(Self.merged(target: target, with: draft))
                availableCandidates.removeAll { $0.id == target.id }
                continue
            }

            draft.importBatchID = batchID
            Self.appendCrossSourceHint(
                for: imported,
                rowIndex: rowOffset + 1,
                accountID: accountID,
                into: &crossSourceHints,
                index: crossSourceIndex
            )
            inserts.append(draft)
            mutations.append(ImportMutation(transactionID: draft.id, kind: .inserted, previousSnapshot: nil))
        }

        let prepared = PreparedImport(
            targetAccountID: accountID,
            providerIdentifier: providerIdentifier,
            totalRows: importedTransactions.count,
            transactions: inserts,
            updates: updates,
            duplicateCount: duplicateCount,
            failedCount: 0,
            issues: [],
            mutations: mutations,
            newMerchants: merchantUpserts.values.sorted { $0.id.uuidString < $1.id.uuidString },
            batch: ImportBatch(
                id: batchID,
                providerIdentifier: providerIdentifier,
                sourceRaw: source.rawValue,
                fileName: nil,
                fileHashSHA256: fileHash,
                startedAt: startedAt,
                completedAt: Date(),
                totalRows: importedTransactions.count,
                importedCount: inserts.count,
                updatedCount: updates.count,
                duplicateCount: duplicateCount,
                failedCount: 0,
                mutations: mutations
            ),
            crossSourceHints: crossSourceHints
        )

        return try await commit(prepared)
    }

    /// Dedup/Import-Edge-Cases:
    /// - a) Gleiche Datei 2x → 2. Mal `duplicateCount == totalRows`, 0 Inserts,
    ///   `isExactFileReplay == true` (FileHash-Frühwarnung), trotzdem row-level
    ///   Dedup (kein Doppelzählen, kein stilles Verwerfen: Row Issues zählen).
    /// - b) Jan drin, dann Dez+Jan+Feb → nur Dez+Feb neu, Jan Duplicates
    ///   (row-level Fingerprint, kein FileHash-Block).
    /// - c) Gleiche Zeilen, anderer Account → KEIN Duplikat (accountID im
    ///   Fingerprint, #20); UI-Text via `ImportDedupNotices.differentAccountHint`.
    /// - d) pending (authorizedAt X) → booked (bookedAt X+2, gleicher
    ///   Betrag/Händler) → `updatedCount == 1` via `PendingBookedReconciler`
    ///   (±0.01, ±7 Tage, Merchant-Ähnlichkeit), kein Insert (Reconciliation,
    ///   nicht bloß Deduplication, #21).
    /// - e) booked-Datum >7 Tage verschoben → KEIN Reconcile (Reconciler-Limit),
    ///   neuer Insert; Limit ist per Test fixiert.
    /// - Cross-Source (dieselbe Buchung schon aus anderer Quelle auf dem Konto,
    ///   z. B. PDF-Auszug vs. CSV-Export): wird übersprungen und als
    ///   `crossSourceDuplicates` gezählt und angezeigt (#18: nicht still).
    ///   Mit `importCrossSourceDuplicates` importiert, dann als Prüfhinweis.
    func prepare(
        _ file: ImportFile,
        into accountID: UUID,
        preferredProviderIdentifier: String? = nil,
        importCrossSourceDuplicates: Bool = false
    ) async throws -> PreparedImport {
        let normalizedFile = try Self.withNormalizedSpreadsheet(file)
        guard let provider = try await detectProvider(for: normalizedFile, preferred: preferredProviderIdentifier) else {
            throw ImportError.unsupportedFormat(reason: String(localized: "Kein passender Import-Provider gefunden."))
        }

        let parseResult = try await provider.parse(normalizedFile)
        let importedTransactions = parseResult.transactions
        let source = provider.transactionSource
        let startedAt = Date()
        let fileHash = ImportBatch.fileHash(of: file.data)
        let importBatchID = UUID()

        // FileHash-Frühwarnung (#1): exakt gleiche Datei (gleicher Hash) wurde
        // schon importiert. Best-effort: Ein Repository-Fehler blockiert den
        // Import nicht, die Warnung bleibt dann aus. Zählung bleibt row-level.
        let isExactFileReplay = await Self.isExactFileReplay(
            fileHash: fileHash,
            repository: importBatchRepository
        )

        let existing = try await transactionRepository.transactions(accountID: accountID, source: source)
        let existingByFingerprint = Dictionary(
            existing.compactMap { txn -> (String, Transaction)? in
                txn.sourceFingerprint.map { ($0, txn) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let existingExternalIDs = Set(
            existing.compactMap { txn -> ExternalTransactionKey? in
                guard let externalID = txn.externalID else { return nil }
                return Self.externalKey(
                    accountID: txn.accountID,
                    source: txn.source,
                    currency: txn.amount.currency,
                    externalID: externalID
                )
            }
        )
        let pendingCandidates = existing.filter {
            $0.status == .pending && $0.accountID == accountID && $0.source == source
        }

        var knownMerchants = try await merchantRepository?.merchants() ?? []
        var merchantUpserts: [Merchant.ID: Merchant] = [:]

        let rules: [CategoryRule]
        if let ruleRepository {
            rules = try await ruleRepository.rules()
        } else {
            rules = []
        }
        let assignableCategoryIDs = try await loadAssignableCategoryIDs()
        let compiledCategoryRules = CategoryRuleEngine().compile(
            rules,
            assignableCategoryIDs: assignableCategoryIDs
        )

        var seenFingerprintsInBatch = Set<String>()
        var seenExternalKeysInBatch = Set<ExternalTransactionKey>()
        var batch: [Transaction] = []
        var updates: [Transaction] = []
        var mutations: [ImportMutation] = []
        var crossSourceHints: [ImportRowIssue] = []
        var crossSourceDuplicates: [ImportRowIssue] = []
        var duplicateCount = 0
        let reconciler = PendingBookedReconciler()
        var availablePendingCandidates = pendingCandidates

        // Dieselbe Buchung aus einer anderen Quelle (PDF vs. CSV, Datei vs.
        // Bankabruf) auf demselben Konto: wird übersprungen und gezählt. Auf
        // Wunsch importiert die Vorschau sie trotzdem, dann als Prüfhinweis.
        // Jede vorhandene Buchung deckt höchstens eine neue Zeile ab.
        var accountQuery = TransactionQuery()
        accountQuery.accountIDs = [accountID]
        let accountWideExisting = try await transactionRepository.transactions(matching: accountQuery)
        let crossSourceMatcher = CrossSourceDuplicateMatcher()
        var crossSourceCandidates = accountWideExisting.filter { $0.source != source }

        var occurrencesByBaseFingerprint: [String: Int] = [:]
        for (rowOffset, imported) in importedTransactions.enumerated() {
            let bookingDate = imported.bookedAt ?? imported.authorizedAt
            let baseFingerprint = TransactionFingerprinter.fingerprint(
                source: source,
                accountID: accountID,
                bookingDate: bookingDate,
                amount: imported.amount,
                merchantOrDescription: imported.rawMerchantName ?? imported.rawDescription ?? "",
                balanceAfter: imported.balanceAfter
            )
            let occurrence = (occurrencesByBaseFingerprint[baseFingerprint] ?? 0) + 1
            occurrencesByBaseFingerprint[baseFingerprint] = occurrence
            let fingerprint = occurrence == 1 ? baseFingerprint : TransactionFingerprinter.fingerprint(
                source: source,
                accountID: accountID,
                bookingDate: bookingDate,
                amount: imported.amount,
                merchantOrDescription: imported.rawMerchantName ?? imported.rawDescription ?? "",
                balanceAfter: imported.balanceAfter,
                occurrence: occurrence
            )

            var externalKey: ExternalTransactionKey?
            if let externalID = imported.externalID {
                externalKey = Self.externalKey(
                    accountID: accountID,
                    source: source,
                    currency: imported.amount.currency,
                    externalID: externalID
                )
            }

            var draft = Self.makeTransaction(
                from: imported,
                source: source,
                accountID: accountID,
                fingerprint: fingerprint
            )

            normalizeAndCategorize(
                &draft,
                rawDescriptor: imported.rawMerchantName ?? imported.rawDescription ?? imported.merchantDisplayName,
                knownMerchants: &knownMerchants,
                merchantUpserts: &merchantUpserts,
                categoryRules: compiledCategoryRules,
                suggestedCategoryID: imported.suggestedCategoryID,
                counterpartyClass: imported.counterpartyClass,
                counterpartyLabel: imported.counterpartyLabel,
                assignableCategoryIDs: assignableCategoryIDs
            )

            if let exact = existingByFingerprint[fingerprint] {
                if exact.status == .pending && imported.status != .pending {
                    mutations.append(ImportMutation(
                        transactionID: exact.id,
                        kind: .updated,
                        previousSnapshot: TransactionSnapshot(transaction: exact)
                    ))
                    updates.append(Self.merged(target: exact, with: draft))
                    availablePendingCandidates.removeAll { $0.id == exact.id }
                } else {
                    duplicateCount += 1
                }
                continue
            }

            if let externalKey, existingExternalIDs.contains(externalKey) {
                if let target = reconciler.findTarget(for: draft, among: availablePendingCandidates) {
                    mutations.append(ImportMutation(
                        transactionID: target.id,
                        kind: .updated,
                        previousSnapshot: TransactionSnapshot(transaction: target)
                    ))
                    updates.append(Self.merged(target: target, with: draft))
                    availablePendingCandidates.removeAll { $0.id == target.id }
                } else {
                    duplicateCount += 1
                }
                continue
            }

            if !seenFingerprintsInBatch.insert(fingerprint).inserted {
                duplicateCount += 1
                continue
            }
            if let externalKey, !seenExternalKeysInBatch.insert(externalKey).inserted {
                duplicateCount += 1
                continue
            }

            if let target = reconciler.findTarget(for: draft, among: availablePendingCandidates) {
                mutations.append(ImportMutation(
                    transactionID: target.id,
                    kind: .updated,
                    previousSnapshot: TransactionSnapshot(transaction: target)
                ))
                updates.append(Self.merged(target: target, with: draft))
                availablePendingCandidates.removeAll { $0.id == target.id }
                continue
            }

            if let existing = crossSourceMatcher.match(draft, among: crossSourceCandidates) {
                crossSourceCandidates.removeAll { $0.id == existing.id }
                let issue = Self.crossSourceIssue(rowIndex: rowOffset + 1, existing: existing)
                if importCrossSourceDuplicates {
                    crossSourceHints.append(issue)
                } else {
                    crossSourceDuplicates.append(issue)
                    continue
                }
            }

            draft.importBatchID = importBatchID
            batch.append(draft)
            mutations.append(ImportMutation(transactionID: draft.id, kind: .inserted, previousSnapshot: nil))
        }

        return PreparedImport(
            targetAccountID: accountID,
            providerIdentifier: provider.identifier,
            totalRows: parseResult.totalRows,
            transactions: batch,
            updates: updates,
            duplicateCount: duplicateCount,
            failedCount: parseResult.issues.count,
            issues: parseResult.issues,
            mutations: mutations,
            newMerchants: merchantUpserts.values.sorted { $0.id.uuidString < $1.id.uuidString },
            batch: ImportBatch(
                id: importBatchID,
                providerIdentifier: provider.identifier,
                sourceRaw: source.rawValue,
                fileName: normalizedFile.fileName,
                fileHashSHA256: fileHash,
                startedAt: startedAt,
                completedAt: startedAt,
                totalRows: parseResult.totalRows,
                importedCount: batch.count,
                updatedCount: updates.count,
                duplicateCount: duplicateCount + crossSourceDuplicates.count,
                failedCount: parseResult.issues.count,
                mutations: mutations
            ),
            isExactFileReplay: isExactFileReplay,
            crossSourceHints: crossSourceHints,
            crossSourceDuplicates: crossSourceDuplicates
        )
    }

    /// Meldet die Bank zu einer bekannten Buchung eine andere Gegenseite
    /// (z. B. nach der Korrektur „Absender statt Empfänger bei Gutschriften"),
    /// werden die Provider-Fakten aktualisiert. Eine vergebene Kategorie und
    /// damit der Typ bleiben unangetastet (User-Entscheidungen gehen vor, #22).
    static func refreshedCounterparty(target: Transaction, with draft: Transaction) -> Transaction? {
        guard let newName = draft.rawMerchantName, newName != target.rawMerchantName,
              // Nur dieselbe Buchung: Eine wiederverwendete Referenz darf
              // keiner anderen Buchung einen fremden Namen geben.
              draft.amount == target.amount,
              Calendar(identifier: .gregorian).isDate(draft.displayDate, inSameDayAs: target.displayDate)
        else { return nil }
        var updated = target
        updated.rawMerchantName = newName
        updated.merchantID = draft.merchantID
        updated.merchantDisplayName = draft.merchantDisplayName
        updated.sourceFingerprint = draft.sourceFingerprint
        if updated.categoryID == nil {
            updated.categoryID = draft.categoryID
            updated.kind = draft.kind
        }
        updated.updatedAt = Date()
        return updated
    }

    private static func merged(target: Transaction, with draft: Transaction) -> Transaction {
        var updated = target
        updated.status = draft.status
        if let bookedAt = draft.bookedAt { updated.bookedAt = bookedAt }
        if let authorizedAt = draft.authorizedAt { updated.authorizedAt = authorizedAt }
        if draft.kind != .unknown && target.kind == .unknown { updated.kind = draft.kind }
        else if target.kind == .unknown { updated.kind = draft.kind }
        updated.sourceFingerprint = draft.sourceFingerprint
        if let merchantID = draft.merchantID { updated.merchantID = merchantID }
        if draft.rawDescription != nil { updated.rawDescription = draft.rawDescription }
        if draft.merchantDisplayName != nil { updated.merchantDisplayName = draft.merchantDisplayName }
        if updated.categoryID == nil { updated.categoryID = draft.categoryID }
        if draft.cashbackAmount != nil { updated.cashbackAmount = draft.cashbackAmount }
        if draft.cashbackCurrency != nil { updated.cashbackCurrency = draft.cashbackCurrency }
        updated.updatedAt = Date()
        return updated
    }

    private func loadAssignableCategoryIDs() async throws -> Set<Category.ID>? {
        guard let categoryRepository else { return nil }
        let categories = try await categoryRepository.categories()
        return Set(CategoryHierarchy().assignableCategories(in: categories).map(\.id))
    }

    private func normalizeAndCategorize(
        _ draft: inout Transaction,
        rawDescriptor: String?,
        knownMerchants: inout [Merchant],
        merchantUpserts: inout [Merchant.ID: Merchant],
        categoryRules: CategoryRuleEngine.CompiledRules,
        suggestedCategoryID: Category.ID?,
        counterpartyClass: CounterpartyClass? = nil,
        counterpartyLabel: String? = nil,
        assignableCategoryIDs: Set<Category.ID>?
    ) {
        // Typ-Normalisierung: Provider liefern meist .unknown, der Typ wird
        // deterministisch aus dem Betragssignal abgeleitet, statt „Unbekannt"
        // zu persistieren (Produkt-Entscheid 30.08.2026).
        draft.kind = TransactionKindInference.inferredKind(
            for: draft.amount,
            current: draft.kind,
            rawDescription: draft.rawDescription,
            merchantName: rawDescriptor
        )

        // PayPal & Co.: Händler ist, wer hinter der Zahlung steht.
        let underlyingMerchant = PaymentIntermediaryResolver.underlyingMerchant(
            rawMerchantName: draft.rawMerchantName,
            rawDescription: draft.rawDescription
        ) ?? counterpartyLabel
        if merchantRepository != nil {
            let resolution = MerchantNormalizer().resolve(
                rawDescriptor: underlyingMerchant ?? rawDescriptor,
                knownMerchants: knownMerchants
            )
            draft.merchantDisplayName = resolution.displayName
            draft.merchantID = resolution.merchantID

            if let merchant = resolution.merchantToUpsert {
                merchantUpserts[merchant.id] = merchant
                if let index = knownMerchants.firstIndex(where: { $0.id == merchant.id }) {
                    knownMerchants[index] = merchant
                } else {
                    knownMerchants.append(merchant)
                }
            }
        } else if let underlyingMerchant {
            draft.merchantDisplayName = underlyingMerchant
        }

        categoryRules.apply(to: &draft, beforeKeywords: counterpartyClass?.categoryID)

        // Regeln (eigene vor Standard) haben Vorrang. Erst wenn keine greift,
        // gilt der Branchen-Vorschlag des Providers, und nur für Kategorien,
        // die es noch gibt und die zuweisbar sind.
        if draft.categoryID == nil,
           let suggestedCategoryID,
           assignableCategoryIDs?.contains(suggestedCategoryID) ?? true {
            draft.categoryID = suggestedCategoryID
        }

    }

    @discardableResult
    func commit(_ prepared: PreparedImport) async throws -> ImportResult {
        if !prepared.newMerchants.isEmpty, let merchantRepository {
            try await merchantRepository.upsert(prepared.newMerchants)
        }

        if var batch = prepared.batch, let importBatchRepository {
            batch.importedCount = prepared.transactions.count
            batch.updatedCount = prepared.updates.count
            batch.completedAt = Date()
            batch.mutations = prepared.mutations

            try await importBatchRepository.commitImport(
                batch: batch,
                inserts: prepared.transactions,
                updates: prepared.updates
            )
        } else {
            try await transactionRepository.upsert(prepared.transactions + prepared.updates)
        }
        // Ist mit dieser Datei die Gegenseite einer Umbuchung angekommen,
        // werden beide Seiten verknüpft und zählen nicht mehr doppelt.
        try await LinkOwnTransfers(transactionRepository: transactionRepository).run()

        return ImportResult(
            providerIdentifier: prepared.providerIdentifier,
            totalRows: prepared.totalRows,
            importedCount: prepared.transactions.count,
            updatedCount: prepared.updates.count,
            duplicateCount: prepared.duplicateCount,
            failedCount: prepared.failedCount,
            isExactFileReplay: prepared.isExactFileReplay,
            crossSourceHintCount: prepared.crossSourceHints.count,
            crossSourceDuplicateCount: prepared.crossSourceDuplicates.count
        )
    }

    /// FileHash-Frühwarnung: prüft, ob exakt gleiche Datei (gleicher SHA256)
    /// schon importiert wurde. Best-effort: Repository-Fehler blockieren den
    /// Import nicht (kein stilles Verwerfen: row-level Dedup zählt trotzdem).
    private static func isExactFileReplay(
        fileHash: String,
        repository: (any ImportBatchRepository)?
    ) async -> Bool {
        guard let repository else { return false }
        guard let batches = try? await repository.batches() else { return false }
        return batches.contains { $0.fileHashSHA256 == fileHash }
    }

    /// Baut den source-agnostischen Index für Cross-Source-Hinweise:
    /// gleicher Account/Tag/Betrag/Währung/Text, aber andere Quelle.
    /// Gleiche Quelle wird ausgeschlossen (das ist exakter Dedup, kein Hinweis).
    private static func crossSourceIndex(
        from transactions: [Transaction],
        excludingSource: TransactionSource
    ) -> [String: Transaction] {
        var index: [String: Transaction] = [:]
        for txn in transactions where txn.source != excludingSource {
            let bookingDate = txn.bookedAt ?? txn.authorizedAt
            let key = TransactionFingerprinter.crossSourceFingerprint(
                accountID: txn.accountID,
                bookingDate: bookingDate,
                amount: txn.amount,
                merchantOrDescription: txn.rawMerchantName ?? txn.rawDescription ?? ""
            )
            if index[key] == nil {
                index[key] = txn
            }
        }
        return index
    }

    private static func crossSourceIssue(rowIndex: Int, existing: Transaction) -> ImportRowIssue {
        ImportRowIssue(
            rowIndex: rowIndex,
            reason: String(localized: "Bereits vorhanden aus \(existing.source.displayName): \(existing.displayDate.formatted(date: .abbreviated, time: .omitted)), \(existing.effectiveMerchantName)")
        )
    }

    /// Markiert einen Cross-Source-Kandidaten als Review-Hinweis statt still
    /// zu duplizieren/mergen. Die Zeile wird trotzdem
    /// importiert; `failedCount` bleibt unberührt (Warnung, kein Fehler).
    private static func appendCrossSourceHint(
        for imported: ImportedTransaction,
        rowIndex: Int,
        accountID: UUID,
        into hints: inout [ImportRowIssue],
        index: [String: Transaction]
    ) {
        let bookingDate = imported.bookedAt ?? imported.authorizedAt
        let key = TransactionFingerprinter.crossSourceFingerprint(
            accountID: accountID,
            bookingDate: bookingDate,
            amount: imported.amount,
            merchantOrDescription: imported.rawMerchantName ?? imported.rawDescription ?? ""
        )
        guard let match = index[key] else { return }
        hints.append(ImportRowIssue(
            rowIndex: rowIndex,
            reason: String(localized: "\(ImportDedupNotices.crossSourceHintPrefix) (gleicher Tag/Betrag/Händler, Quelle \(match.source.displayName)). Kein automatischer Abgleich, bitte in der Review-Queue prüfen.")
        ))
    }

    private static func makeTransaction(
        from imported: ImportedTransaction,
        source: TransactionSource,
        accountID: UUID,
        fingerprint: String
    ) -> Transaction {
        let now = Date()
        return Transaction(
            accountID: accountID,
            source: source,
            externalID: imported.externalID,
            sourceFingerprint: fingerprint,
            status: imported.status,
            kind: imported.kind,
            amount: imported.amount,
            bookedAt: imported.bookedAt,
            authorizedAt: imported.authorizedAt,
            valueDate: nil,
            rawDescription: imported.rawDescription,
            rawMerchantName: imported.rawMerchantName,
            merchantDisplayName: imported.merchantDisplayName,
            categoryID: nil,
            paymentMethod: imported.paymentMethod,
            originalCurrency: imported.originalCurrency,
            originalAmount: imported.originalAmount,
            cryptoAsset: imported.cryptoAsset,
            cryptoAmount: imported.cryptoAmount,
            cashbackAmount: imported.cashbackAmount,
            cashbackCurrency: imported.cashbackCurrency,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func externalKey(
        accountID: UUID,
        source: TransactionSource,
        currency: CurrencyCode,
        externalID: String
    ) -> ExternalTransactionKey {
        ExternalTransactionKey(
            accountID: accountID,
            source: source,
            currency: currency,
            externalID: externalID
        )
    }

    func detectProvider(
        for file: ImportFile,
        preferred preferredIdentifier: String? = nil
    ) async throws -> (any ImportProvider)? {
        let normalizedFile = try Self.withNormalizedSpreadsheet(file)

        if let preferredIdentifier,
           let preferred = providers.first(where: { $0.identifier == preferredIdentifier }) {
            if try await preferred.canHandle(normalizedFile) {
                return preferred
            }
            throw ImportError.unsupportedFormat(
                reason: String(localized: "Die Datei entspricht nicht dem Format von \(preferred.displayName).")
            )
        }

        for provider in providers {
            if try await provider.canHandle(normalizedFile) {
                return provider
            }
        }
        return nil
    }

    static func withNormalizedSpreadsheet(_ file: ImportFile) throws -> ImportFile {
        if PDFStatementConverter.isPDF(file.data) {
            do {
                let csvText = try PDFStatementConverter.csvText(from: file.data)
                return ImportFile(fileName: file.fileName, data: Data(csvText.utf8))
            } catch PDFStatementError.noText {
                throw ImportError.unsupportedFormat(
                    reason: String(localized: "Das PDF enthält keinen lesbaren Text (vermutlich ein Scan).")
                )
            } catch PDFStatementError.noTable {
                throw ImportError.unsupportedFormat(
                    reason: String(localized: "Im PDF wurde keine Umsatztabelle mit Datum und Betrag gefunden.")
                )
            } catch {
                throw ImportError.unsupportedFormat(
                    reason: String(localized: "Das PDF konnte nicht geöffnet werden (beschädigt oder passwortgeschützt).")
                )
            }
        }
        guard XLSXConverter.isZipArchive(file.data) else { return file }
        let csvText = try XLSXConverter.csvText(from: file.data)
        return ImportFile(fileName: file.fileName, data: Data(csvText.utf8))
    }

    func headers(of file: ImportFile) -> [String]? {
        guard let normalizedFile = try? Self.withNormalizedSpreadsheet(file),
              let document = try? CSVReader.parse(normalizedFile.data),
              !document.headers.isEmpty else {
            return nil
        }
        return document.headers
    }
}
