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

    @MainActor
    func recordOpened(_ dependencies: AppDependencies) async {
        do {
            // Erstes Laden der Übersicht, wie beim Öffnen des Fensters; so
            // misst der Rauchtest auch die Zeit im fertigen Release-Build.
            let cold = await DashboardModel(dependencies: dependencies).measureLoad()
            // Zweites Laden mit frischem Model: wie jeder spätere Start, wenn
            // Kurse schon im Cache liegen.
            let warm = await DashboardModel(dependencies: dependencies).measureLoad()
            let accounts = try await dependencies.accountRepository.accounts().count
            let transactions = try await dependencies.transactionRepository.transactions(matching: TransactionQuery()).count
            let categories = try await dependencies.categoryRepository.categories().count
            func milliseconds(_ duration: Duration) -> Int64 {
                duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
            }
            write("ok accounts=\(accounts) transactions=\(transactions) categories=\(categories) overviewVisibleMs=\(milliseconds(cold.visible)) overviewCompleteMs=\(milliseconds(cold.complete)) warmVisibleMs=\(milliseconds(warm.visible)) warmCompleteMs=\(milliseconds(warm.complete)) widgetStore=\(WidgetSnapshotStore.shared() != nil ? "available" : "none")")
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
