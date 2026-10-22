import Foundation

@MainActor
@Observable
final class ImportModel {
    enum Phase: Equatable {
        case idle
        case running
        case reviewing(fileName: String?, providerName: String)
        case needsAccount(suggestedName: String)
        case needsMapping
        case completed(ImportResult)
        case failed(String)
    }

    private let dependencies: AppDependencies

    private(set) var phase: Phase = .idle
    private(set) var accounts: [Account] = []
    private(set) var preparedImport: PreparedImport?
    private(set) var lastCompletedBatchID: UUID?
    private(set) var recentBatches: [ImportBatch] = []
    private(set) var mappingHeaders: [String] = []
    private(set) var isRollingBack = false

    var selectedAccountID: UUID?

    var preparedTargetAccountName: String? {
        guard let targetAccountID = preparedImport?.targetAccountID else { return nil }
        return accounts.first(where: { $0.id == targetAccountID })?.name
    }

    var canChangeTargetAccount: Bool {
        guard preparedImport == nil else { return false }
        if case .running = phase { return false }
        return true
    }

    private var pendingFile: ImportFile?

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    /// Währung für Zeilen ohne eigene Währungsangabe: die des Zielkontos:
    /// Eine US-Datei in ein USD-Konto bleibt USD.
    private var targetCurrency: CurrencyCode {
        accounts.first { $0.id == selectedAccountID }?.currency ?? dependencies.baseCurrency
    }

    private var pipeline: ImportPipeline {
        let currency = targetCurrency
        return ImportPipeline(
            providers: dependencies.importProviders.map { provider in
                provider is GenericCSVProvider ? GenericCSVProvider(fallbackCurrency: currency) : provider
            },
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            merchantRepository: dependencies.merchantRepository,
            categoryRepository: dependencies.categoryRepository,
            fallbackCurrency: dependencies.baseCurrency
        )
    }

    func loadAccounts() async {
        do {
            // Getrennte (inaktive) Konten sind kein Importziel.
            accounts = try await dependencies.accountRepository.accounts().filter(\.isActive)
            if selectedAccountID == nil {
                selectedAccountID = accounts.first(where: { $0.type == .checking })?.id ?? accounts.first?.id
            }
        } catch {
            phase = .failed(String(localized: "Konten konnten nicht geladen werden."))
        }
    }

    func loadHistory() async {
        do {
            // Alle Importe: Ein Fehlimport muss auch dann noch rückholbar
            // sein, wenn danach mehrere Bankabrufe liefen (die Ansicht zeigt
            // zunächst nur die neuesten).
            recentBatches = try await dependencies.importBatchRepository.batches()
        } catch {
            recentBatches = []
        }
    }

    /// Benennt einen Import nach seinem Weg in die App (Datei oder
    /// Bankabruf), nicht nach dem Format der Datei.
    func displayName(forProviderIdentifier identifier: String) -> String {
        ImportBatchDisplayNames.fallback(for: identifier)
    }

    func prepareFile(at url: URL) async {
        phase = .running
        preparedImport = nil
        lastCompletedBatchID = nil
        do {
            // Datei-I/O + Provider-Erkennung + Parsing laufen
            // im Hintergrund (Task.detached); das Model bleibt @MainActor
            // für State (phase/preparedImport), Loading-State via .running.
            let file = try await Task.detached(priority: .userInitiated) {
                try await ImportFileLoader().load(at: url)
            }.value
            pendingFile = file

            let pipelineSnapshot = pipeline
            let detected = try await Task.detached(priority: .userInitiated) {
                try await pipelineSnapshot.detectProvider(for: file)
            }.value

            guard selectedAccountID != nil else {
                phase = .needsAccount(
                    suggestedName: ""
                )
                return
            }

            try await process(file: file, detectedProvider: detected)
        } catch let error as ImportError {
            phase = .failed(error.userFacingMessage)
        } catch {
            phase = .failed(String(localized: "Die Datei konnte nicht gelesen werden."))
        }
    }

    func fileSelectionFailed() {
        preparedImport = nil
        lastCompletedBatchID = nil
        phase = .failed(String(localized: "Die Dateiauswahl ist fehlgeschlagen. Bitte versuche es erneut."))
    }

    /// Legt ein neues Zielkonto an und wählt es aus, z. B. für den ersten
    /// Export einer Bank, die noch kein Konto in der App hat.
    @discardableResult
    func createAccount(named name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canChangeTargetAccount else { return false }
        let account = Account(name: trimmed, type: .checking, currency: dependencies.baseCurrency, source: .csvImport)
        do {
            try await dependencies.accountRepository.upsert([account])
        } catch {
            phase = .failed(String(localized: "Das Konto konnte nicht erstellt werden."))
            return false
        }
        await loadAccounts()
        selectedAccountID = account.id
        dependencies.changeTracker.markChanged()
        return true
    }

    func createAccountAndContinue(named name: String) async {
        guard let file = pendingFile else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        phase = .idle
        guard await createAccount(named: name) else { return }
        phase = .running

        do {
            let pipelineSnapshot = pipeline
            let detected = try await Task.detached(priority: .userInitiated) {
                try await pipelineSnapshot.detectProvider(for: file)
            }.value
            try await process(file: file, detectedProvider: detected)
        } catch let error as ImportError {
            phase = .failed(error.userFacingMessage)
        } catch {
            phase = .failed(String(localized: "Die Datei konnte nicht verarbeitet werden."))
        }
    }

    private func process(file: ImportFile, detectedProvider: (any ImportProvider)?) async throws {
        if let provider = detectedProvider {
            try await runPreparation(file, providerDisplayName: provider.displayName, provider: provider)
            return
        }

        // XLSX-Normalisierung (XLSXConverter.csvText) +
        // CSV-Parsing (CSVReader.parse) laufen synchron und CPU-lastig,
        // deshalb im Hintergrund, nicht auf dem MainActor.
        let pipelineSnapshot = pipeline
        let headers = await Task.detached(priority: .userInitiated) {
            pipelineSnapshot.headers(of: file)
        }.value
        guard let headers, !headers.isEmpty else {
            phase = .failed(String(localized: "Die Datei konnte nicht gelesen werden: keine Tabellenstruktur erkannt."))
            return
        }

        mappingHeaders = headers
        phase = .needsMapping
    }

    func applyManualMapping(
        dateColumn: String,
        amountColumn: String,
        descriptionColumn: String?,
        merchantColumn: String?,
        currencyColumn: String?,
        externalIDColumn: String?
    ) async {
        guard let file = pendingFile else { return }
        phase = .running

        let mapping = GenericCSVMapping(
            dateColumn: dateColumn,
            amountColumn: amountColumn,
            descriptionColumn: emptyToNil(descriptionColumn),
            merchantColumn: emptyToNil(merchantColumn),
            currencyColumn: emptyToNil(currencyColumn),
            externalIDColumn: emptyToNil(externalIDColumn)
        )

        let forcedProvider = GenericCSVProvider(
            fallbackCurrency: targetCurrency,
            forcedMapping: mapping
        )

        do {
            try await runPreparation(
                file,
                providerDisplayName: String(localized: "Spalten manuell zugeordnet"),
                provider: forcedProvider
            )
        } catch let error as ImportError {
            phase = .failed(error.userFacingMessage)
        } catch {
            phase = .failed(String(localized: "Die Zuordnung konnte nicht angewendet werden."))
        }
    }

    private func runPreparation(
        _ file: ImportFile,
        providerDisplayName: String,
        provider: any ImportProvider
    ) async throws {
        guard let accountID = selectedAccountID else {
            phase = .needsAccount(suggestedName: "")
            return
        }

        let singleProviderPipeline = ImportPipeline(
            providers: [provider],
            transactionRepository: dependencies.transactionRepository,
            ruleRepository: dependencies.ruleRepository,
            importBatchRepository: dependencies.importBatchRepository,
            merchantRepository: dependencies.merchantRepository,
            categoryRepository: dependencies.categoryRepository,
            fallbackCurrency: dependencies.baseCurrency
        )

        phase = .running
        // prepare (Spreadsheet-Normalisierung via
        // XLSXConverter.csvText, CSVReader.parse, Fingerprint-/Rule-Loop)
        // läuft im Hintergrund; State-Updates bleiben auf dem MainActor.
        let prepared = try await Task.detached(priority: .userInitiated) {
            try await singleProviderPipeline.prepare(file, into: accountID)
        }.value

        if prepared.transactions.isEmpty
            && prepared.updates.isEmpty
            && prepared.duplicateCount > 0 {
            phase = .completed(
                ImportResult(
                    providerIdentifier: provider.identifier,
                    totalRows: prepared.totalRows,
                    importedCount: 0,
                    updatedCount: 0,
                    duplicateCount: prepared.duplicateCount,
                    failedCount: prepared.failedCount,
                    isExactFileReplay: prepared.isExactFileReplay,
                    crossSourceHintCount: prepared.crossSourceHints.count
                )
            )
            pendingFile = nil
            preparedImport = nil
            await loadHistory()
            return
        }

        preparedImport = prepared
        phase = .reviewing(fileName: file.fileName, providerName: providerDisplayName)
    }

    func confirmImport() async {
        guard let prepared = preparedImport else { return }
        phase = .running
        do {
            let result = try await pipeline.commit(prepared)
            phase = .completed(result)
            if let batch = prepared.batch {
                lastCompletedBatchID = batch.id
                await mirrorCashWithdrawals(importBatchID: batch.id)
            }
            dependencies.changeTracker.markChanged()
            await loadHistory()
        } catch {
            phase = .failed(String(localized: "Der Import ist fehlgeschlagen."))
        }
        pendingFile = nil
        preparedImport = nil
    }

    /// Bargeld-Automatik nach dem Import: erkannte Abhebungen dieses Batches
    /// ins eingestellte Bargeldkonto spiegeln. Fehler ändern das
    /// Importergebnis nicht.
    private func mirrorCashWithdrawals(importBatchID: UUID) async {
        guard dependencies.preferences.cashWithdrawalTargetAccountID != nil,
              let accountID = selectedAccountID else { return }
        var query = TransactionQuery()
        query.accountIDs = [accountID]
        guard let rows = try? await dependencies.transactionRepository.transactions(matching: query) else { return }
        let candidates = rows.filter { $0.importBatchID == importBatchID }
        _ = try? await MirrorCashWithdrawal(dependencies: dependencies).mirrorDetectedWithdrawals(in: candidates)
    }

    func rollback(batchID: UUID) async {
        guard !isRollingBack else { return }
        isRollingBack = true
        defer { isRollingBack = false }
        do {
            try await dependencies.importBatchRepository.rollbackImportBatch(id: batchID)
            if lastCompletedBatchID == batchID {
                lastCompletedBatchID = nil
                if case .completed = phase {
                    phase = .idle
                }
            }
            dependencies.changeTracker.markChanged()
            await loadHistory()
        } catch {
            phase = .failed(String(localized: "Der Import konnte nicht rückgängig gemacht werden."))
        }
    }

    func rollbackLastImport() async {
        guard let batchID = lastCompletedBatchID else { return }
        await rollback(batchID: batchID)
    }

    var canRollbackLastImport: Bool {
        lastCompletedBatchID != nil
    }

    func reset() {
        pendingFile = nil
        preparedImport = nil
        mappingHeaders = []
        phase = .idle
    }

    private func emptyToNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

enum ImportBatchDisplayNames {
    static func fallback(for identifier: String) -> String {
        switch identifier {
        case "etherfi_cash_csv", "metamask_card_csv", "generic_csv": String(localized: "Datei-Import")
        case "enablebanking": String(localized: "Bankabruf (Enable Banking)")
        case "gocardless": String(localized: "Bankabruf (GoCardless)")
        default: identifier
        }
    }
}
