import Testing

@testable import FinanceTracker

@Suite("Backup-Wiederherstellung: Inhaltsangabe")
struct BackupRestoreSummaryTests {
    @Test("Einzahl und Mehrzahl werden korrekt gebildet")
    func pluralization() {
        #expect(
            PreparedBackupRestore.summary(accounts: 1, transactions: 1, budgets: 1, attachments: 1)
                == "1 Konto · 1 Buchung · 1 Budget · 1 Beleg"
        )
        #expect(
            PreparedBackupRestore.summary(accounts: 3, transactions: 185, budgets: 0, attachments: 2)
                == "3 Konten · 185 Buchungen · 0 Budgets · 2 Belege"
        )
    }
}
