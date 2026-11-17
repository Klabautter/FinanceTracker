import Foundation

@MainActor
@Observable
final class SettingsModel {
    /// Nur, was dieser Typ nutzt (Roadmap 7.4, `DependencyCapabilities`).
    typealias Dependencies = any HasAccountRepository & HasBackupRestoreService & HasBankProviderFactory & HasBankSyncCoordinator & HasBaseCurrency & HasBudgetRepository & HasCategoryRepository & HasChangeTracker & HasConnectionRepository & HasFxRateProvider & HasImportBatchRepository & HasMerchantRepository & HasNotificationScheduler & HasPreferences & HasRecurringCommitmentRepository & HasRuleRepository & HasSharedExpenseShareRepository & HasTagRepository & HasTransactionAnnotationRepository & HasTransactionAttachmentRepository & HasTransactionCollectionOverrideRepository & HasTransactionCollectionRepository & HasTransactionRepository & HasTransactionSplitRepository

    static let notificationsEnabledKey = "localNotificationsEnabled"

    private let dependencies: Dependencies
    private let defaults: UserDefaults
    private let notificationService: any LocalNotificationScheduling
    private let healthEvaluator = ConnectionHealthEvaluator()

    private(set) var isResetting = false
    private(set) var message: String?

    private(set) var isPreparingExport = false
    private(set) var isRestoring = false
    private(set) var preparedRestore: PreparedBackupRestore?
    /// Ein mit Passwort geschütztes Backup, das auf sein Passwort wartet.
    struct LockedBackup: Equatable {
        let fileName: String
        let data: Data
    }
    private(set) var lockedRestore: LockedBackup?
    /// Fehler der Passworteingabe beim Wiederherstellen (falsches Passwort).
    private(set) var restorePasswordError: String?
    private(set) var isUnlockingRestore = false
    private(set) var dataMessage: String?
    /// Sicherheitskopie vor der letzten Wiederherstellung (zum Anzeigen im Finder).
    private(set) var lastSafetyBackupURL: URL?
    var isBusyWithData: Bool { isPreparingExport || isRestoring }

    func prepareCSVExport() async -> TransactionsCSVDocument? {
        guard !isBusyWithData else { return nil }
        isPreparingExport = true
        dataMessage = nil
        defer { isPreparingExport = false }
        do { return try await CSVExportService.makeDocument(dependencies: dependencies) }
        catch { dataMessage = String(localized: "Export konnte nicht erstellt werden."); return nil }
    }

    /// Was an einem neuen Backup-Passwort nicht stimmt; `nil`, wenn es passt.
    static func backupPasswordProblem(_ password: String, repeated: String) -> String? {
        BackupEncryption.passwordProblem(password, repeated: repeated)
    }

    /// - Parameter password: Mit Passwort wird das fertige Archiv
    ///   verschlüsselt (Roadmap 9.3). Das Passwort wird nicht gespeichert.
    func prepareBackupExport(includeAttachments: Bool = true, password: String? = nil) async -> BackupPackageDocument? {
        guard !isBusyWithData else { return nil }
        isPreparingExport = true
        dataMessage = nil
        defer { isPreparingExport = false }
        do {
            // Kein Bankabruf währenddessen: sonst könnten Zeilen zwischen den
            // einzelnen Ladeschritten fehlen oder doppelt sein.
            let dependencies = dependencies
            let package = try await dependencies.bankSyncCoordinator.runExclusively {
                try await BackupService.makeBackupPackage(dependencies: dependencies, includeAttachments: includeAttachments)
            }
            guard let password else { return BackupPackageDocument(data: package) }
            // Schlüsselableitung und Verschlüsselung dauern spürbar: nicht auf dem MainActor.
            let data = try await Task.detached(priority: .userInitiated) {
                try BackupEncryption.encrypt(package, password: password)
            }.value
            return BackupPackageDocument(data: data)
        } catch { dataMessage = String(localized: "Backup konnte nicht erstellt werden: \(error.localizedDescription)"); return nil }
    }

    /// Löscht alle Finanzdaten dieses Macs. Vorher entsteht automatisch eine
    /// vollständige Sicherheitskopie; ohne sie wird nichts gelöscht. Der
    /// Bank-Schlüssel im Schlüsselbund bleibt (eigene Aktion unter Konten).
    func deleteAllData() async {
        guard !isBusyWithData else { return }
        isRestoring = true
        dataMessage = nil
        defer { isRestoring = false }
        do {
            let dependencies = dependencies
            let target = try await dependencies.bankSyncCoordinator.runExclusively {
                let data = try await BackupService.makeBackupPackage(dependencies: dependencies)
                let target = try AttachmentService.defaultBaseDirectory().deletingLastPathComponent()
                    .appendingPathComponent("RestoreSafety", isDirectory: true)
                    .appendingPathComponent("FinanceTracker-vor-Loeschen-\(UUID().uuidString).ftbackup")
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target, options: .atomic)
                }.value
                try await LocalDataResetService(dependencies: dependencies).wipe()
                return target
            }
            lastSafetyBackupURL = target
            await refreshLocalNotifications()
            dataMessage = String(localized: "Alle Daten wurden gelöscht. Der vorherige Stand ist als Sicherheitskopie gespeichert.")
        } catch {
            dataMessage = String(localized: "Löschen abgebrochen, es wurde nichts entfernt: \(error.localizedDescription)")
        }
    }

    func prepareRestore(from url: URL) async {
        guard !isBusyWithData else { return }
        isRestoring = true
        dataMessage = nil
        preparedRestore = nil
        lockedRestore = nil
        restorePasswordError = nil
        defer { isRestoring = false }
        do {
            let loaded: (prepared: PreparedBackupRestore?, locked: Data?) = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let size, size <= BackupRestoreService.maxArchiveBytes + BackupEncryption.overhead else {
                    throw BackupError.invalidRestore(String(localized: "Backup-Datei ist zu groß."))
                }
                let data = try Data(contentsOf: url)
                // Ein geschütztes Backup wird erst mit Passwort geprüft.
                if BackupEncryption.isEncrypted(data) { return (nil, data) }
                return (try BackupRestoreService.prepare(data), nil)
            }.value
            preparedRestore = loaded.prepared
            lockedRestore = loaded.locked.map { LockedBackup(fileName: url.lastPathComponent, data: $0) }
        } catch { dataMessage = String(localized: "Backup wurde nicht übernommen: \(error.localizedDescription)") }
    }

    /// Öffnet das wartende Backup mit dem Passwort und prüft es wie jedes
    /// andere. Liefert `true`, wenn es zur Bestätigung bereitsteht.
    func unlockRestore(password: String) async -> Bool {
        guard !isUnlockingRestore, let locked = lockedRestore else { return false }
        isUnlockingRestore = true
        restorePasswordError = nil
        defer { isUnlockingRestore = false }
        do {
            let data = locked.data
            preparedRestore = try await Task.detached(priority: .userInitiated) {
                try BackupRestoreService.prepare(BackupEncryption.decrypt(data, password: password))
            }.value
            lockedRestore = nil
            return true
        } catch let error as BackupEncryptionError {
            // Eingabefehler: bleibt im Passwort-Dialog, das Backup wartet weiter.
            restorePasswordError = error.localizedDescription
            return false
        } catch {
            lockedRestore = nil
            dataMessage = String(localized: "Backup wurde nicht übernommen: \(error.localizedDescription)")
            return false
        }
    }

    func cancelLockedRestore() {
        lockedRestore = nil
        restorePasswordError = nil
    }

    func cancelRestore() { preparedRestore = nil }

    func confirmRestore() async {
        guard !isBusyWithData, let preparedRestore, let service = dependencies.backupRestoreService else { return }
        isRestoring = true
        dataMessage = nil
        defer { isRestoring = false; self.preparedRestore = nil }
        var safetyURL: URL?
        do {
            let data = try await BackupService.makeBackupPackage(dependencies: dependencies)
            let attachments = try AttachmentService.defaultBaseDirectory()
            let target = attachments.deletingLastPathComponent()
                .appendingPathComponent("RestoreSafety", isDirectory: true)
                .appendingPathComponent("FinanceTracker-\(UUID().uuidString).ftbackup")
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }.value
            safetyURL = target
            // Kein Bankabruf währenddessen: Er schriebe alte Buchungen in
            // den wiederhergestellten Bestand.
            try await dependencies.bankSyncCoordinator.runExclusively {
                try await service.replace(with: preparedRestore, attachmentsDirectory: attachments)
            }
            dependencies.changeTracker.markChanged()
            await refreshLocalNotifications()
            lastSafetyBackupURL = target
            dataMessage = String(localized: "Backup wiederhergestellt. Der vorherige Stand ist als Sicherheitskopie gespeichert.")
        } catch {
            lastSafetyBackupURL = safetyURL
            let failure = String(localized: "Wiederherstellung fehlgeschlagen: \(error.localizedDescription)")
            dataMessage = safetyURL == nil
                ? failure
                : failure + " " + String(localized: "Der vorherige Stand ist als Sicherheitskopie gespeichert.")
        }
    }

    var baseCurrency: CurrencyCode { dependencies.baseCurrency }

    // MARK: - Mitteilungen (P1, Opt-in, lokal, lesend)

    private(set) var notificationsEnabled: Bool
    private(set) var isUpdatingNotifications = false
    private(set) var notificationMessage: String?

    // MARK: - Wechselkurse (EZB, #19/#35)

    /// FX-Status für UI-Debug (Quelle live/cache/fallback + Stand).
    /// Laden blockiert nie: Bei Fehlern gilt der statische Fallback.
    private(set) var fxSnapshot: FXRateSnapshot?
    private(set) var fxIsLoading = false

    init(
        dependencies: Dependencies,
        defaults: UserDefaults = .standard,
        notificationService: any LocalNotificationScheduling = LocalNotificationService()
    ) {
        self.dependencies = dependencies
        self.defaults = defaults
        self.notificationService = notificationService
        self.notificationsEnabled = defaults.bool(forKey: Self.notificationsEnabledKey)
        self.cashWithdrawalTargetAccountID = dependencies.preferences.cashWithdrawalTargetAccountID
        self.automaticBankSyncEnabled = dependencies.preferences.automaticBankSyncEnabled
    }

    // MARK: - Automatischer Bankabruf

    /// Verbundene Banken von selbst abrufen; Änderungen landen sofort in
    /// den Einstellungen.
    var automaticBankSyncEnabled: Bool {
        didSet {
            guard automaticBankSyncEnabled != oldValue else { return }
            dependencies.preferences.setAutomaticBankSyncEnabled(automaticBankSyncEnabled)
        }
    }

    // MARK: - Bargeld-Automatik

    /// Aktive Bargeldkonten als Ziel für erkannte Abhebungen.
    private(set) var cashAccounts: [Account] = []

    /// Ziel der Bargeld-Automatik (nil = aus); Änderungen landen sofort in
    /// den Einstellungen.
    var cashWithdrawalTargetAccountID: UUID? {
        didSet {
            guard cashWithdrawalTargetAccountID != oldValue else { return }
            dependencies.preferences.setCashWithdrawalTargetAccountID(cashWithdrawalTargetAccountID)
        }
    }

    func loadCashAccounts() async {
        let accounts = (try? await dependencies.accountRepository.accounts()) ?? []
        cashAccounts = accounts
            .filter { $0.type == .cash && $0.isActive }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Ein gelöschtes oder deaktiviertes Zielkonto schaltet die Automatik aus.
        if let target = cashWithdrawalTargetAccountID, !cashAccounts.contains(where: { $0.id == target }) {
            cashWithdrawalTargetAccountID = nil
        }
    }

    /// Lädt den FX-Status für die Anzeige (EZB live → 24h-Cache → statische
    /// Referenzkurse). Blockiert nichts: Der Provider wirft bei
    /// Netzwerkfehlern nicht, sondern liefert den Fallback-Snapshot.
    /// Kein Secret-Logging: Snapshots enthalten nur öffentliche Kurse.
    func loadFXRates() async {
        await fetchFXRates(forceRefresh: false)
    }

    /// Explicit user refresh bypasses the fresh local cache and tries the ECB feed.
    func refreshFXRates() async {
        await fetchFXRates(forceRefresh: true)
    }

    private func fetchFXRates(forceRefresh: Bool) async {
        guard !fxIsLoading else { return }
        fxIsLoading = true
        defer { fxIsLoading = false }
        fxSnapshot = forceRefresh
            ? await dependencies.fxRateProvider.refresh()
            : await dependencies.fxRateProvider.snapshot()
    }

    /// Schaltet den Opt-in um. Aktivieren fragt die System-Freigabe an und
    /// wertet danach EINMALIG lokal aus (kein Hintergrund-Sync, #15);
    /// Deaktivieren löscht alle geplanten Hinweise.
    func setNotificationsEnabled(_ enabled: Bool) async {
        guard !isUpdatingNotifications else { return }
        isUpdatingNotifications = true
        notificationMessage = nil
        defer { isUpdatingNotifications = false }

        if enabled {
            let granted = await notificationService.requestAuthorization()
            guard granted else {
                defaults.set(false, forKey: Self.notificationsEnabledKey)
                notificationsEnabled = false
                notificationMessage = String(localized: "Mitteilungen wurden im System nicht erlaubt. Bitte in den Systemeinstellungen freigeben.")
                return
            }
            defaults.set(true, forKey: Self.notificationsEnabledKey)
            notificationsEnabled = true
            await refreshLocalNotifications()
        } else {
            defaults.set(false, forKey: Self.notificationsEnabledKey)
            notificationsEnabled = false
            await notificationService.clearAll()
            notificationMessage = nil
        }
    }

    /// Reine Vorschau (kein System-Call) für UI und Tests.
    func previewNotifications(
        budgetProgresses: [BudgetProgress],
        commitments: [RecurringCommitment],
        syncIssues: [NotificationSyncIssue],
        now: Date = Date()
    ) -> [PendingLocalNotification] {
        dependencies.notificationScheduler.makeNotifications(
            budgetProgresses: budgetProgresses,
            commitments: commitments,
            syncIssues: syncIssues,
            now: now
        )
    }

    /// Wertet lokal aus (Budgets mit ihren konfigurierten Perioden über dieselbe
    /// Contribution-Pipeline wie Budgets/Analytics, #28; Fixkosten mit
    /// `nextExpectedDate`; Sync-Hinweise aus abgelaufenen/blockierten
    /// Connections) und plant System-Hinweise. Kein einziger Bank-Netzwerk-
    /// Call; ohne Zustimmung findet kein Hintergrund-Sync statt.
    func refreshLocalNotifications(now: Date = Date()) async {
        guard notificationsEnabled else {
            await notificationService.clearAll()
            return
        }
        do {
            let calendar = Calendar.current
            let loader = LoadBudgetProgresses(
                budgetRepository: dependencies.budgetRepository,
                transactionRepository: dependencies.transactionRepository,
                annotationRepository: dependencies.transactionAnnotationRepository,
                splitRepository: dependencies.transactionSplitRepository,
                commitmentRepository: dependencies.recurringCommitmentRepository,
                fxRateProvider: dependencies.fxRateProvider
            )
            async let budgetResultTask = loader.execute(now: now, calendar: calendar, baseCurrency: baseCurrency)
            async let connectionsTask = dependencies.connectionRepository.connections()
            let (budgetResult, connections) = try await (budgetResultTask, connectionsTask)
            let commitments = try await commitmentsWithNextDueDates(budgetResult.commitments, now: now, calendar: calendar)
            guard notificationsEnabled else { return }
            let syncIssues = connections
                .filter {
                    switch healthEvaluator.health(for: $0, now: now, calendar: calendar) {
                    case .expired, .blocked: true
                    case .noConsentInfo, .healthy, .expiring: false
                    }
                }
                .map { NotificationSyncIssue(connectionID: $0.id, providerDisplayName: $0.displayName) }

            let pending = dependencies.notificationScheduler.makeNotifications(
                budgetProgresses: budgetResult.progresses,
                commitments: commitments,
                syncIssues: syncIssues,
                now: now,
                calendar: calendar
            ) + dependencies.notificationScheduler.consentReminders(for: connections, now: now, calendar: calendar)
            await notificationService.clearAll()
            await notificationService.schedule(pending)
        } catch {
            notificationMessage = String(localized: "Hinweise konnten nicht aktualisiert werden.")
        }
    }

    /// Fixkosten mit dem Termin, den auch „Anstehend" zeigt: aus der letzten
    /// Zahlung fortgeschrieben. Die gespeicherte Planung bliebe sonst auf dem
    /// längst bezahlten Termin stehen und der Hinweis käme nie wieder.
    private func commitmentsWithNextDueDates(
        _ commitments: [RecurringCommitment],
        now: Date,
        calendar: Calendar
    ) async throws -> [RecurringCommitment] {
        let active = commitments.filter { $0.status == .active }
        guard !active.isEmpty,
              let historyStart = calendar.date(byAdding: .month, value: -6, to: now),
              let historyEnd = calendar.date(byAdding: .month, value: 1, to: now) else { return commitments }
        var query = TransactionQuery()
        query.dateInterval = DateInterval(start: historyStart, end: historyEnd)
        let rows = try await dependencies.transactionRepository.transactions(matching: query)
        let annotations = try await dependencies.transactionAnnotationRepository.annotations(
            transactionIDs: Set(rows.map(\.id))
        )
        let history = EffectiveTransactionResolver().applying(annotations: annotations, to: rows)
        let occurrencesByCommitment = Dictionary(
            grouping: try await dependencies.recurringCommitmentRepository.allOccurrences(),
            by: \.commitmentID
        )
        let resolver = RecurringOccurrenceResolver()
        return commitments.map { commitment in
            guard commitment.status == .active else { return commitment }
            var planned = commitment
            planned.nextExpectedDate = resolver.nextDueDate(
                commitment: commitment,
                explicitOccurrences: occurrencesByCommitment[commitment.id] ?? [],
                allTransactions: history,
                now: now,
                calendar: calendar
            )
            return planned
        }
    }

    /// WP-UX: Entfernt NUR die Demo-Transaktionen und -Konten (Source = demo);
    /// echte Daten (openBanking/manual/Import) bleiben unangetastet.
    func removeDemoData() async {
        guard !isResetting else { return }
        isResetting = true
        message = nil
        defer { isResetting = false }

        do {
            try await LocalDataResetService(dependencies: dependencies).removeDemoData()
            message = String(localized: "Demo-Daten wurden entfernt.")
        } catch {
            message = String(localized: "Demo-Daten konnten nicht entfernt werden.")
        }
    }
}
