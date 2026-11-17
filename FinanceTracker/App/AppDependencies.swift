import Foundation
import SwiftData

struct AppDependencies: Sendable {
    let transactionRepository: any TransactionRepository
    let transactionAnnotationRepository: any TransactionAnnotationRepository
    let transactionCollectionRepository: any TransactionCollectionRepository
    let transactionCollectionOverrideRepository: any TransactionCollectionOverrideRepository
    let accountRepository: any AccountRepository
    let categoryRepository: any CategoryRepository
    let merchantRepository: any MerchantRepository
    let ruleRepository: any CategoryRuleRepository
    let importBatchRepository: any ImportBatchRepository
    let connectionRepository: any ConnectionRepository
    let budgetRepository: any BudgetRepository
    let tagRepository: any TagRepository
    let transactionSplitRepository: any TransactionSplitRepository
    let sharedExpenseShareRepository: any SharedExpenseShareRepository
    let recurringCommitmentRepository: any RecurringCommitmentRepository
    let transactionAttachmentRepository: any TransactionAttachmentRepository
    let bankProviderFactory: any BankProviderResolving
    let importProviders: [any ImportProvider]
    let changeTracker: DataChangeTracker
    let baseCurrency: CurrencyCode
    /// Reine Scheduler-Regeln (80/100 %, 3-Tage-Fenster, Sync-Hinweise),
    /// kein Singleton, keine Übermittlung (die liegt an der App-Grenze).
    let notificationScheduler: NotificationScheduler
    /// Live-Wechselkurse (EZB) für die Fremdwährungs-Umrechnung (#19/#35).
    /// Lazy per Konstruktion: Der Init macht kein I/O; erst `snapshot()`
    /// lädt: 24h-Datei-Cache zuerst, dann Live-Feed, dann statische
    /// Referenzkurse als Fallback (niemals Throw bei Netzwerkfehlern).
    /// Kein Singleton; Verdrahtung ausschließlich hier.
    let fxRateProvider: any FXRateProvider
    let backupRestoreService: BackupRestoreService?
    /// Nutzereinstellungen außerhalb der Datenbank (z. B. Bargeld-Automatik).
    let preferences: any AppPreferences
    /// Ablage für kleine UI-Zustände (ausgeblendete Vorschläge, Zuordnungen
    /// von Buchungsarten). Im Demo-Modus ein eigener, leerer Bereich, damit
    /// Durchläufe die echten Einstellungen nicht verändern.
    /// Gespeichert wird nur der Name des Bereichs (`nil` = Standard), damit
    /// die Abhängigkeiten ohne `@unchecked` `Sendable` sind; `UserDefaults`
    /// selbst ist threadsicher, aber nicht als `Sendable` markiert.
    let userDefaultsSuiteName: String?
    var userDefaults: UserDefaults {
        userDefaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
    /// Kategorie-Vorschläge aus dem Händlernamen über das Sprachmodell des
    /// Geräts. `nil`, wo es keines gibt, und in Tests.
    let categoryAdvisor: (any MerchantCategoryAdvisor)?
    /// Eine Instanz pro App: liest den Schlüsselbund nur einmal pro Lauf.
    let enableBankingCredentialStore: any EnableBankingCredentialStoring
    /// Bankliste je Land, damit der Verbinden-Dialog beim zweiten Mal sofort steht.
    let bankInstitutionCache: BankInstitutionCache
    /// Eine Instanz pro App: reiht alle Bankabrufe (Knopf, „Alle
    /// aktualisieren“, Automatik) hintereinander und hält ihren Zustand.
    let bankSyncCoordinator: BankSyncCoordinator

    init(
        transactionRepository: any TransactionRepository,
        transactionAnnotationRepository: any TransactionAnnotationRepository,
        transactionCollectionRepository: any TransactionCollectionRepository,
        transactionCollectionOverrideRepository: any TransactionCollectionOverrideRepository,
        accountRepository: any AccountRepository,
        categoryRepository: any CategoryRepository,
        merchantRepository: any MerchantRepository,
        ruleRepository: any CategoryRuleRepository,
        importBatchRepository: any ImportBatchRepository,
        connectionRepository: any ConnectionRepository,
        budgetRepository: any BudgetRepository,
        tagRepository: any TagRepository,
        transactionSplitRepository: any TransactionSplitRepository,
        sharedExpenseShareRepository: any SharedExpenseShareRepository,
        recurringCommitmentRepository: any RecurringCommitmentRepository,
        transactionAttachmentRepository: any TransactionAttachmentRepository,
        bankProviderFactory: any BankProviderResolving,
        importProviders: [any ImportProvider],
        changeTracker: DataChangeTracker,
        baseCurrency: CurrencyCode,
        notificationScheduler: NotificationScheduler,
        fxRateProvider: any FXRateProvider = ECBFXRateProvider(loadsHistory: false),
        backupRestoreService: BackupRestoreService? = nil,
        preferences: any AppPreferences = UserDefaultsAppPreferences(),
        userDefaultsSuiteName: String? = nil,
        categoryAdvisor: (any MerchantCategoryAdvisor)? = nil,
        enableBankingCredentialStore: any EnableBankingCredentialStoring = KeychainEnableBankingCredentialStore(),
        bankInstitutionCache: BankInstitutionCache = BankInstitutionCache(),
        bankSyncCoordinator: BankSyncCoordinator = BankSyncCoordinator()
    ) {
        self.transactionRepository = transactionRepository
        self.transactionAnnotationRepository = transactionAnnotationRepository
        self.transactionCollectionRepository = transactionCollectionRepository
        self.transactionCollectionOverrideRepository = transactionCollectionOverrideRepository
        self.accountRepository = accountRepository
        self.categoryRepository = categoryRepository
        self.merchantRepository = merchantRepository
        self.ruleRepository = ruleRepository
        self.importBatchRepository = importBatchRepository
        self.connectionRepository = connectionRepository
        self.budgetRepository = budgetRepository
        self.tagRepository = tagRepository
        self.transactionSplitRepository = transactionSplitRepository
        self.sharedExpenseShareRepository = sharedExpenseShareRepository
        self.recurringCommitmentRepository = recurringCommitmentRepository
        self.transactionAttachmentRepository = transactionAttachmentRepository
        self.bankProviderFactory = bankProviderFactory
        self.importProviders = importProviders
        self.changeTracker = changeTracker
        self.baseCurrency = baseCurrency
        self.notificationScheduler = notificationScheduler
        self.fxRateProvider = fxRateProvider
        self.backupRestoreService = backupRestoreService
        self.preferences = preferences
        self.userDefaultsSuiteName = userDefaultsSuiteName
        self.categoryAdvisor = categoryAdvisor
        self.enableBankingCredentialStore = enableBankingCredentialStore
        self.bankInstitutionCache = bankInstitutionCache
        self.bankSyncCoordinator = bankSyncCoordinator
    }

    /// Basiswährung für Summen und Prognosen (Einstellungen → Allgemein).
    /// Nur Währungen mit Referenzkurs; sonst EUR. Wirkt ab dem nächsten Start.
    static let baseCurrencyDefaultsKey = "baseCurrency"

    static func storedBaseCurrency(in defaults: UserDefaults) -> CurrencyCode {
        guard let raw = defaults.string(forKey: baseCurrencyDefaultsKey) else { return .eur }
        let code = CurrencyCode(raw)
        return selectableBaseCurrencies.contains(code) ? code : .eur
    }

    static var selectableBaseCurrencies: [CurrencyCode] {
        ([CurrencyCode.eur] + CurrencyConverter.referenceEURRates.keys).sorted { $0.rawValue < $1.rawValue }
    }

    static func live() throws -> AppDependencies {
        // Normale UI-/Visual-QA-Läufe verwenden bewusst den Live-Store.
        // Nur künstliche Empty-/Storage-Error-Zustände sind isoliert.
        let launch = AppLaunchEnvironment.live
        // Als Host der Unit-Tests nie die Entwicklungs-Datenbank öffnen:
        // Migration und Startschritte liefen sonst gegen echte Testdaten.
        let unitTestStore = AppDataDirectory.unitTestRoot()?.appendingPathComponent("FinanceTracker.store")
        let location: StoreLocation = (launch.uiTestStoreURL ?? unitTestStore).map { .url($0) } ?? .live
        let store = try SwiftDataStore(location: location)
        var userDefaultsSuiteName: String?
        if launch.isSmokeTestMode {
            // Rauchtest der fertigen App: eigene, leere Einstellungen, damit
            // er nichts in die Einstellungen der Installation schreibt.
            let suite = "de.klabautter.FinanceTracker.smoke-test"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            userDefaultsSuiteName = suite
        }
        #if DEBUG
        if launch.isScreenshotDemoMode {
            PreviewDependencies.seedDemoData(into: store.container)
            let suite = "de.klabautter.FinanceTracker.screenshot-demo"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            userDefaultsSuiteName = suite
        }
        #endif
        return make(
            container: store.container,
            baseCurrency: Self.storedBaseCurrency(in: userDefaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard),
            // Als Host der Unit-Tests keine Kurs-Historie aus dem Netz laden.
            fxRateProvider: ECBFXRateProvider(loadsHistory: AppDataDirectory.unitTestRoot() == nil),
            userDefaultsSuiteName: userDefaultsSuiteName,
            categoryAdvisor: MerchantCategoryAdvisorFactory.systemAdvisor()
        )
    }

    static func make(
        container: ModelContainer,
        baseCurrency: CurrencyCode,
        importProviders: [any ImportProvider] = [],
        notificationScheduler: NotificationScheduler = NotificationScheduler(),
        bankProviderFactory: (any BankProviderResolving)? = nil,
        fxRateProvider: (any FXRateProvider)? = nil,
        preferences: (any AppPreferences)? = nil,
        userDefaultsSuiteName: String? = nil,
        categoryAdvisor: (any MerchantCategoryAdvisor)? = nil
    ) -> AppDependencies {
        let enableBankingCredentialStore = KeychainEnableBankingCredentialStore()
        return AppDependencies(
            transactionRepository: LocalTransactionRepository(modelContainer: container),
            transactionAnnotationRepository: LocalTransactionAnnotationRepository(modelContainer: container),
            transactionCollectionRepository: LocalTransactionCollectionRepository(modelContainer: container),
            transactionCollectionOverrideRepository: LocalTransactionCollectionOverrideRepository(modelContainer: container),
            accountRepository: LocalAccountRepository(modelContainer: container),
            categoryRepository: LocalCategoryRepository(modelContainer: container),
            merchantRepository: LocalMerchantRepository(modelContainer: container),
            ruleRepository: LocalCategoryRuleRepository(modelContainer: container),
            importBatchRepository: LocalImportBatchRepository(modelContainer: container),
            connectionRepository: LocalConnectionRepository(modelContainer: container),
            budgetRepository: LocalBudgetRepository(modelContainer: container),
            tagRepository: LocalTagRepository(modelContainer: container),
            transactionSplitRepository: LocalTransactionSplitRepository(modelContainer: container),
            sharedExpenseShareRepository: LocalSharedExpenseShareRepository(modelContainer: container),
            recurringCommitmentRepository: LocalRecurringCommitmentRepository(modelContainer: container),
            transactionAttachmentRepository: LocalTransactionAttachmentRepository(modelContainer: container),
            bankProviderFactory: bankProviderFactory ?? RoutedBankProviderFactory(
                enableBanking: EnableBankingProviderFactory(
                    redirectURL: EnableBankingProviderFactory.defaultRedirectURL,
                    credentialStore: enableBankingCredentialStore
                ),
                goCardless: GoCardlessPoCProviderFactory(
                    credentialStore: KeychainGoCardlessCredentialStore()
                )
            ),
            importProviders: importProviders.isEmpty
                ? [GenericCSVProvider(fallbackCurrency: baseCurrency)]
                : importProviders,
            changeTracker: DataChangeTracker(),
            baseCurrency: baseCurrency,
            notificationScheduler: notificationScheduler,
            // Tageskurs-Historie nur in der App (`live()`), nicht in Tests.
            fxRateProvider: fxRateProvider ?? ECBFXRateProvider(loadsHistory: false),
            backupRestoreService: BackupRestoreService(modelContainer: container),
            preferences: preferences ?? UserDefaultsAppPreferences(),
            userDefaultsSuiteName: userDefaultsSuiteName,
            categoryAdvisor: categoryAdvisor,
            enableBankingCredentialStore: enableBankingCredentialStore
        )
    }
}

extension MirrorCashWithdrawal {
    init(dependencies: AppDependencies) {
        self.init(
            transactionRepository: dependencies.transactionRepository,
            annotationRepository: dependencies.transactionAnnotationRepository,
            accountRepository: dependencies.accountRepository,
            preferences: dependencies.preferences
        )
    }
}
