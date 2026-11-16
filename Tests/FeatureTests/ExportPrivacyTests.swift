import Foundation
import Testing

@testable import FinanceTracker

@Suite("ExportPrivacy")
struct ExportPrivacyTests {
    @Test("CSV-Export entschärft Formeln, Beträge bleiben Zahlen")
    func csvNeutralizesFormulas() {
        #expect(TransactionsCSVExporter.escape("=HYPERLINK(\"x\")").hasPrefix("\"'="))
        #expect(TransactionsCSVExporter.escape("+49 Shop") == "'+49 Shop")
        #expect(TransactionsCSVExporter.escape("@SUM(A1)") == "'@SUM(A1)")
        #expect(TransactionsCSVExporter.escape("-12.50") == "-12.50")
        #expect(TransactionsCSVExporter.escape("-Rabatt") == "'-Rabatt")
        #expect(TransactionsCSVExporter.escape("REWE") == "REWE")
    }

    @Test("Logs kürzen Konto- und Sitzungskennungen im Pfad")
    func endpointRedaction() {
        let path = "/accounts/1b2f6e3a-9c4d-4e5f-8a7b-6c5d4e3f2a1b/transactions"
        let redacted = BankSyncService.redacted(path)
        #expect(redacted == "/accounts/…2a1b/transactions")
    }

    @Test("Backup enthält keine Sitzungs-ID der Bank")
    func backupOmitsSessionID() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let connection = Connection(
            id: UUID(), userID: UUID(), provider: .enablebanking, providerConnectionID: "session-secret",
            institutionID: "DE_BANK", status: .active, consentExpiresAt: nil,
            lastSuccessfulSyncAt: nil, createdAt: Date(), updatedAt: Date()
        )
        try await dependencies.connectionRepository.upsert([connection])
        let backup = try await BackupService.makeBackup(dependencies: dependencies)
        #expect(backup.connections.count == 1)
        #expect(backup.connections.first?.providerConnectionID == nil)
        let json = String(data: try BackupService.encode(backup), encoding: .utf8) ?? ""
        #expect(!json.contains("session-secret"))
    }
}
