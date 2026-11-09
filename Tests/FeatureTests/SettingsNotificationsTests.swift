import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("SettingsNotifications")
struct SettingsNotificationsTests {
    actor MockNotificationService: LocalNotificationScheduling {
        let granted: Bool
        private(set) var scheduledBatches: [[PendingLocalNotification]] = []
        private(set) var clearedCount = 0

        init(granted: Bool) { self.granted = granted }

        func requestAuthorization() async -> Bool { granted }
        func schedule(_ notifications: [PendingLocalNotification]) async {
            scheduledBatches.append(notifications)
        }
        func clearAll() async { clearedCount += 1 }
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-notifications-\(UUID().uuidString)")!
    }

    private func makeModel(granted: Bool, defaults: UserDefaults? = nil) throws -> (SettingsModel, MockNotificationService, UserDefaults) {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let service = MockNotificationService(granted: granted)
        let suite = defaults ?? isolatedDefaults()
        let model = SettingsModel(dependencies: dependencies, defaults: suite, notificationService: service)
        return (model, service, suite)
    }

    @Test("Opt-in ist standardmäßig aus")
    func defaultOff() throws {
        let (model, _, _) = try makeModel(granted: true)
        #expect(!model.notificationsEnabled)
    }

    @Test("Aktivieren mit Freigabe persistiert und wertet lokal aus (kein Bank-Call)")
    func enablePersists() async throws {
        let (model, service, suite) = try makeModel(granted: true)
        await model.setNotificationsEnabled(true)
        #expect(model.notificationsEnabled)
        #expect(suite.bool(forKey: SettingsModel.notificationsEnabledKey))
        #expect(await service.clearedCount >= 1, "Refresh räumt alte Hinweise vor dem Planen ab")
    }

    @Test("Aktivieren ohne System-Freigabe bleibt aus mit Hinweis")
    func deniedStaysOff() async throws {
        let (model, _, suite) = try makeModel(granted: false)
        await model.setNotificationsEnabled(true)
        #expect(!model.notificationsEnabled)
        #expect(!suite.bool(forKey: SettingsModel.notificationsEnabledKey))
        #expect(model.notificationMessage?.contains("System") == true)
    }

    @Test("Deaktivieren löscht geplante Hinweise")
    func disableClears() async throws {
        let (model, service, _) = try makeModel(granted: true)
        await model.setNotificationsEnabled(true)
        let clearedAfterEnable = await service.clearedCount
        await model.setNotificationsEnabled(false)
        #expect(!model.notificationsEnabled)
        #expect(await service.clearedCount > clearedAfterEnable)
    }

    @Test("Vorschau nutzt Scheduler-Regeln (80 % warnt)")
    func previewUsesScheduler() throws {
        let (model, _, _) = try makeModel(granted: true)
        let budget = Budget(name: "Essen", amount: Decimal(100))
        let progress = BudgetProgress(
            budget: budget,
            spent: Decimal(85),
            currency: .eur,
            period: DateInterval(start: .distantPast, end: .distantFuture)
        )
        let preview = model.previewNotifications(budgetProgresses: [progress], commitments: [], syncIssues: [])
        #expect(preview.count == 1)
        #expect(preview[0].kind == .budgetWarning80)
    }
    @Test("Mitteilungen berücksichtigen abweichenden Budgetstart statt nur Kalendermonate")
    func customPeriodUsesSharedPipeline() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))!
        let account = Account(name: "Test", type: .checking, currency: .eur, source: .manual)
        let categoryID = UUID()
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.budgetRepository.upsert([
            Budget(name: "Monat ab dem 15.", amount: 100, periodPolicy: .calendarMonth(startDay: 15), categoryIDs: [categoryID], createdAt: now)
        ])
        try await dependencies.transactionRepository.upsert([
            Transaction(accountID: account.id, source: .manual, status: .booked, kind: .purchase,
                        amount: Money(amount: -85, currency: .eur),
                        bookedAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: 20)), categoryID: categoryID)
        ])
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: SettingsModel.notificationsEnabledKey)
        let service = MockNotificationService(granted: true)
        let model = SettingsModel(dependencies: dependencies, defaults: defaults, notificationService: service)
        await model.refreshLocalNotifications(now: now)
        let batches = await service.scheduledBatches
        #expect(batches.last?.contains { $0.kind == .budgetWarning80 } == true)
        #expect(model.notificationMessage == nil)
    }

    @Test("Fixkosten-Hinweis folgt dem nächsten Termin aus der letzten Zahlung, nicht der veralteten Planung")
    func commitmentNoticeUsesNextDueDateFromPayments() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 9))!
        let lastPayment = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        // Die gespeicherte Planung zeigt noch auf den bezahlten Oktober-Termin;
        // nichts schaltet sie weiter. Fällig ist der 15.11., in zwei Tagen.
        try await dependencies.recurringCommitmentRepository.upsert([
            RecurringCommitment(
                name: "Netflix",
                merchantKey: "NETFLIX",
                direction: .expense,
                cadence: .monthly,
                amountPolicy: .fixed,
                expectedAmount: 13,
                currency: .eur,
                nextExpectedDate: lastPayment,
                status: .active
            )
        ])
        try await dependencies.transactionRepository.upsert([
            Transaction(accountID: account.id, source: .manual, status: .booked, kind: .purchase,
                        amount: Money(amount: -13, currency: .eur), bookedAt: lastPayment,
                        rawDescription: "Netflix", rawMerchantName: "Netflix", merchantDisplayName: "Netflix")
        ])
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: SettingsModel.notificationsEnabledKey)
        let service = MockNotificationService(granted: true)
        let model = SettingsModel(dependencies: dependencies, defaults: defaults, notificationService: service)

        await model.refreshLocalNotifications(now: now)

        let batches = await service.scheduledBatches
        let due = try #require(batches.last?.first { $0.kind == .commitmentDueSoon })
        #expect(due.body == "„Netflix“ ist in 2 Tagen fällig.")
        #expect(model.notificationMessage == nil)
    }

    @Test("Budgetstart am 31. beginnt im Februar am letzten Tag")
    func clampedPeriodStart() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 2, day: 28))!
        let interval = BudgetPeriodResolver().calendarMonthInterval(startDay: 31, containing: now, calendar: calendar)
        #expect(interval.start == now)
        #expect(interval.containsHalfOpen(now))
        #expect(calendar.component(.day, from: interval.end) == 31)
    }

}
