import Foundation

@MainActor
@Observable
final class SettingsModel {
    static let notificationsEnabledKey = "localNotificationsEnabled"

    private let dependencies: AppDependencies
    private let defaults: UserDefaults
    private let notificationService: any LocalNotificationScheduling
    private let healthEvaluator = ConnectionHealthEvaluator()

    private(set) var isResetting = false
    private(set) var message: String?

    private(set) var isPreparingExport = false
    private(set) var isRestoring = false
    private(set) var preparedRestore: PreparedBackupRestore?
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

    func prepareBackupExport(includeAttachments: Bool = true) async -> BackupPackageDocument? {
        guard !isBusyWithData else { return nil }
        isPreparingExport = true
        dataMessage = nil
        defer { isPreparingExport = false }
        do {
            return BackupPackageDocument(data: try await BackupService.makeBackupPackage(dependencies: dependencies, includeAttachments: includeAttachments))
        } catch { dataMessage = String(localized: "Backup konnte nicht erstellt werden: \(error.localizedDescription)"); return nil }
    }

    func prepareRestore(from url: URL) async {
        guard !isBusyWithData else { return }
        isRestoring = true
        dataMessage = nil
        preparedRestore = nil
        defer { isRestoring = false }
        do {
            preparedRestore = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let size, size <= BackupRestoreService.maxArchiveBytes else {
                    throw BackupError.invalidRestore(String(localized: "Backup-Datei ist zu groß."))
                }
                return try BackupRestoreService.prepare(Data(contentsOf: url))
            }.value
        } catch { dataMessage = String(localized: "Backup wurde nicht übernommen: \(error.localizedDescription)") }
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
            try await service.replace(with: preparedRestore, attachmentsDirectory: attachments)
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
        dependencies: AppDependencies,
        defaults: UserDefaults = .standard,
        notificationService: any LocalNotificationScheduling = LocalNotificationService()
    ) {
        self.dependencies = dependencies
        self.defaults = defaults
        self.notificationService = notificationService
        self.notificationsEnabled = defaults.bool(forKey: Self.notificationsEnabledKey)
        self.cashWithdrawalTargetAccountID = dependencies.preferences.cashWithdrawalTargetAccountID
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
            if notificationMessage == nil {
                notificationMessage = String(localized: "Mitteilungen sind aktiv. Hinweise entstehen nur aus lokalen Daten.")
            }
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
                commitments: budgetResult.commitments,
                syncIssues: syncIssues,
                now: now,
                calendar: calendar
            )
            await notificationService.clearAll()
            await notificationService.schedule(pending)
        } catch {
            notificationMessage = String(localized: "Hinweise konnten nicht aktualisiert werden.")
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
