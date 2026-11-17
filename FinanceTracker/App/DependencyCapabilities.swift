import Foundation

/// Fähigkeiten von `AppDependencies` (Roadmap 7.4): Ein Feature-Model
/// verlangt nur die Bausteine, die es nutzt, z. B.
/// `any HasCategoryRepository & HasChangeTracker`. `AppDependencies`
/// erfüllt alle; Aufrufer und Tests reichen sie weiter wie bisher. Der
/// Compiler verhindert, dass ein Model unbemerkt weitere Daten anfasst.

protocol HasTransactionRepository: Sendable { var transactionRepository: any TransactionRepository { get } }
protocol HasTransactionAnnotationRepository: Sendable { var transactionAnnotationRepository: any TransactionAnnotationRepository { get } }
protocol HasTransactionCollectionRepository: Sendable { var transactionCollectionRepository: any TransactionCollectionRepository { get } }
protocol HasTransactionCollectionOverrideRepository: Sendable { var transactionCollectionOverrideRepository: any TransactionCollectionOverrideRepository { get } }
protocol HasAccountRepository: Sendable { var accountRepository: any AccountRepository { get } }
protocol HasCategoryRepository: Sendable { var categoryRepository: any CategoryRepository { get } }
protocol HasMerchantRepository: Sendable { var merchantRepository: any MerchantRepository { get } }
protocol HasRuleRepository: Sendable { var ruleRepository: any CategoryRuleRepository { get } }
protocol HasImportBatchRepository: Sendable { var importBatchRepository: any ImportBatchRepository { get } }
protocol HasConnectionRepository: Sendable { var connectionRepository: any ConnectionRepository { get } }
protocol HasBudgetRepository: Sendable { var budgetRepository: any BudgetRepository { get } }
protocol HasTagRepository: Sendable { var tagRepository: any TagRepository { get } }
protocol HasTransactionSplitRepository: Sendable { var transactionSplitRepository: any TransactionSplitRepository { get } }
protocol HasSharedExpenseShareRepository: Sendable { var sharedExpenseShareRepository: any SharedExpenseShareRepository { get } }
protocol HasRecurringCommitmentRepository: Sendable { var recurringCommitmentRepository: any RecurringCommitmentRepository { get } }
protocol HasTransactionAttachmentRepository: Sendable { var transactionAttachmentRepository: any TransactionAttachmentRepository { get } }
protocol HasBankProviderFactory: Sendable { var bankProviderFactory: any BankProviderResolving { get } }
protocol HasImportProviders: Sendable { var importProviders: [any ImportProvider] { get } }
protocol HasChangeTracker: Sendable { var changeTracker: DataChangeTracker { get } }
protocol HasBaseCurrency: Sendable { var baseCurrency: CurrencyCode { get } }
protocol HasNotificationScheduler: Sendable { var notificationScheduler: NotificationScheduler { get } }
protocol HasFxRateProvider: Sendable { var fxRateProvider: any FXRateProvider { get } }
protocol HasBackupRestoreService: Sendable { var backupRestoreService: BackupRestoreService? { get } }
protocol HasPreferences: Sendable { var preferences: any AppPreferences { get } }
protocol HasUserDefaults: Sendable { var userDefaults: UserDefaults { get } }
protocol HasCategoryAdvisor: Sendable { var categoryAdvisor: (any MerchantCategoryAdvisor)? { get } }
protocol HasEnableBankingCredentialStore: Sendable { var enableBankingCredentialStore: any EnableBankingCredentialStoring { get } }
protocol HasBankInstitutionCache: Sendable { var bankInstitutionCache: BankInstitutionCache { get } }
protocol HasBankSyncCoordinator: Sendable { var bankSyncCoordinator: BankSyncCoordinator { get } }

extension AppDependencies: HasTransactionRepository, HasTransactionAnnotationRepository, HasTransactionCollectionRepository, HasTransactionCollectionOverrideRepository, HasAccountRepository, HasCategoryRepository, HasMerchantRepository, HasRuleRepository, HasImportBatchRepository, HasConnectionRepository, HasBudgetRepository, HasTagRepository, HasTransactionSplitRepository, HasSharedExpenseShareRepository, HasRecurringCommitmentRepository, HasTransactionAttachmentRepository, HasBankProviderFactory, HasImportProviders, HasChangeTracker, HasBaseCurrency, HasNotificationScheduler, HasFxRateProvider, HasBackupRestoreService, HasPreferences, HasUserDefaults, HasCategoryAdvisor, HasEnableBankingCredentialStore, HasBankInstitutionCache, HasBankSyncCoordinator {}
