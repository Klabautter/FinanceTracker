import Foundation

/// Rauchtest der fertigen App (Roadmap 4.5, `Scripts/smoke-test-app.sh`):
/// Mit `-smoke-test <name>` öffnet die App den vorbereiteten Store im
/// isolierten Ordner, führt die Start-Migrationen aus, liest Konten,
/// Buchungen und Kategorien und schreibt das Ergebnis nach
/// `smoke-result.txt`. Danach beendet sie sich. Kein Bankabruf, keine
/// Änderung am echten Store.
struct AppSmokeTest: Sendable {
    let resultURL: URL

    static var current: AppSmokeTest? {
        guard AppDataDirectory.smokeTestName() != nil,
              let root = AppDataDirectory.isolatedRoot() else { return nil }
        return AppSmokeTest(resultURL: root.appendingPathComponent("smoke-result.txt"))
    }

    func recordOpened(_ dependencies: AppDependencies) async {
        do {
            let accounts = try await dependencies.accountRepository.accounts().count
            let transactions = try await dependencies.transactionRepository.transactions(matching: TransactionQuery()).count
            let categories = try await dependencies.categoryRepository.categories().count
            write("ok accounts=\(accounts) transactions=\(transactions) categories=\(categories)")
        } catch {
            write("failed: read \(type(of: error))")
        }
    }

    func recordOpenFailure() {
        write("failed: open")
    }

    private func write(_ line: String) {
        try? Data((line + "\n").utf8).write(to: resultURL, options: .atomic)
    }
}
