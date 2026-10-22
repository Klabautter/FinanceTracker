import Foundation
import SwiftData

struct AppDependencies: @unchecked Sendable {
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
    /// Kategorie-Vorschläge aus dem Händlernamen über das Sprachmodell des
    /// Geräts. `nil`, wo es keines gibt, und in Tests.
    let categoryAdvisor: (any MerchantCategoryAdvisor)?
    /// Eine Instanz pro App: liest den Schlüsselbund nur einmal pro Lauf.
    let enableBankingCredentialStore: any EnableBankingCredentialStoring
    /// Bankliste je Land, damit der Verbinden-Dialog beim zweiten Mal sofort steht.
    let bankInstitutionCache: BankInstitutionCache

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
        fxRateProvider: any FXRateProvider = ECBFXRateProvider(),
        backupRestoreService: BackupRestoreService? = nil,
        preferences: any AppPreferences = UserDefaultsAppPreferences(),
        categoryAdvisor: (any MerchantCategoryAdvisor)? = nil,
        enableBankingCredentialStore: any EnableBankingCredentialStoring = KeychainEnableBankingCredentialStore(),
        bankInstitutionCache: BankInstitutionCache = BankInstitutionCache()
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
        self.categoryAdvisor = categoryAdvisor
        self.enableBankingCredentialStore = enableBankingCredentialStore
        self.bankInstitutionCache = bankInstitutionCache
    }

    static func live() throws -> AppDependencies {
        // Normale UI-/Visual-QA-Läufe verwenden bewusst den Live-Store.
        // Nur künstliche Empty-/Storage-Error-Zustände sind isoliert.
        let launch = AppLaunchEnvironment.live
        let location: StoreLocation = launch.uiTestStoreURL.map { .url($0) } ?? .live
        let store = try SwiftDataStore(location: location)
        #if DEBUG
        if launch.isScreenshotDemoMode {
            PreviewDependencies.seedDemoData(into: store.container)
        }
        #endif
        return make(
            container: store.container,
            baseCurrency: .eur,
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
                ? [
                    EtherFiCSVProvider(fallbackCurrency: baseCurrency),
                    MetaMaskCardCSVProvider(fallbackCurrency: baseCurrency),
                    GenericCSVProvider(fallbackCurrency: baseCurrency)
                ]
                : importProviders,
            changeTracker: DataChangeTracker(),
            baseCurrency: baseCurrency,
            notificationScheduler: notificationScheduler,
            fxRateProvider: fxRateProvider ?? ECBFXRateProvider(),
            backupRestoreService: BackupRestoreService(modelContainer: container),
            preferences: preferences ?? UserDefaultsAppPreferences(),
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
