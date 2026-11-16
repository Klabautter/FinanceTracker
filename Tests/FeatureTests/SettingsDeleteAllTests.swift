import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("SettingsDeleteAll")
struct SettingsDeleteAllTests {
    actor SilentNotifications: LocalNotificationScheduling {
        func requestAuthorization() async -> Bool { false }
        func schedule(_ notifications: [PendingLocalNotification]) async {}
        func clearAll() async {}
    }

    @Test("Alle Daten löschen speichert vorher eine Sicherheitskopie, die sich wiederherstellen lässt")
    func deleteAllKeepsSafetyCopy() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let account = Account(name: "Giro", type: .checking, currency: .eur, source: .manual)
        try await dependencies.accountRepository.upsert([account])
        try await dependencies.transactionRepository.upsert([Transaction(
            accountID: account.id, source: .manual, externalID: "1", status: .booked, kind: .purchase,
            amount: Money(amount: -12, currency: .eur), bookedAt: Date(),
            rawDescription: "Bäcker", rawMerchantName: "Bäcker", merchantDisplayName: "Bäcker"
        )])
        let model = SettingsModel(
            dependencies: dependencies,
            defaults: UserDefaults(suiteName: "delete-all-\(UUID().uuidString)")!,
            notificationService: SilentNotifications()
        )

        await model.deleteAllData()

        #expect(try await dependencies.transactionRepository.count() == 0)
        #expect(try await dependencies.accountRepository.accounts().isEmpty)
        let safety = try #require(model.lastSafetyBackupURL)
        defer { try? FileManager.default.removeItem(at: safety) }
        let prepared = try BackupRestoreService.prepare(Data(contentsOf: safety))
        #expect(prepared.backup.transactions.count == 1)
    }
}
