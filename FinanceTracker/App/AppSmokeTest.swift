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
            let transactions = try await dependencies.transactionRepository.count()
            let categories = try await dependencies.categoryRepository.categories().count
            func milliseconds(_ duration: Duration) -> Int64 {
                duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
            }
            write("ok accounts=\(accounts) transactions=\(transactions) categories=\(categories) overviewVisibleMs=\(milliseconds(cold.visible)) overviewCompleteMs=\(milliseconds(cold.complete)) warmVisibleMs=\(milliseconds(warm.visible)) warmCompleteMs=\(milliseconds(warm.complete)) widgetStore=\(WidgetSnapshotStore.shared() != nil ? "available" : "none") peakMemoryMB=\(Self.peakFootprintMegabytes().map(String.init) ?? "unknown")")
        } catch {
            write("failed: read \(type(of: error))")
        }
    }

    /// Höchster Speicherbedarf des Prozesses (wie in der Aktivitätsanzeige),
    /// für das Leistungsbudget (Roadmap 3.8: unter 200 MB).
    static func peakFootprintMegabytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.ledger_phys_footprint_peak / 1_024 / 1_024
    }

    func recordOpenFailure() {
        write("failed: open")
    }

    private func write(_ line: String) {
        try? Data((line + "\n").utf8).write(to: resultURL, options: .atomic)
    }
}
