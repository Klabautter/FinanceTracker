import Foundation

/// Rauchtest der fertigen App (Roadmap 4.5, `Scripts/smoke-test-app.sh`):
/// Mit `-smoke-test <name>` richtet die App einen isolierten Ordner ein
/// (mit `-smoke-fixture-stdin` samt dem hereingereichten Fixture-Store),
/// öffnet den Store dort, führt die Start-Migrationen aus, liest Konten,
/// Buchungen und Kategorien und gibt das Ergebnis auf der Standardausgabe
/// aus. Danach räumt sie den Ordner weg und beendet sich. Kein Bankabruf,
/// keine Änderung am echten Store.
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

    /// Das Ergebnis geht auf die Standardausgabe (das Skript liest sie über
    /// `open --stdout`) und zusätzlich in eine Datei im Testordner. Der
    /// Weg über die Standardausgabe braucht keinen Zugriff des Terminals auf
    /// den Container der App, den macOS für andere Programme sperren kann.
    private func write(_ line: String) {
        try? Data((line + "\n").utf8).write(to: resultURL, options: .atomic)
        print("\(Self.resultPrefix)\(line)")
        fflush(stdout)
    }

    static let resultPrefix = "smoke-result: "
    static let fixtureFromStandardInputArgument = "-smoke-fixture-stdin"

    enum PreparationError: Error {
        case emptyFixture
    }

    /// Richtet den Testordner frisch ein, bevor die Datenbank geöffnet wird:
    /// Reste eines früheren Laufs verschwinden, und mit
    /// `-smoke-fixture-stdin` wird der Fixture-Store von der Standardeingabe
    /// gelesen (das Skript reicht ihn über `open --stdin` herein). So muss
    /// kein anderes Programm in den Container der App schreiben.
    static func prepareIsolatedStore(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        standardInput: FileHandle = .standardInput
    ) throws {
        guard AppDataDirectory.smokeTestName(arguments: arguments) != nil,
              let root = AppDataDirectory.isolatedRoot(arguments: arguments) else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        guard arguments.contains(fixtureFromStandardInputArgument) else { return }
        let fixture = try standardInput.readToEnd() ?? Data()
        guard !fixture.isEmpty else { throw PreparationError.emptyFixture }
        try fixture.write(to: root.appendingPathComponent("FinanceTracker.store"), options: .atomic)
    }

    /// Entfernt den Testordner nach dem Lauf (bestmöglich; der nächste Lauf
    /// räumt ohnehin zuerst auf).
    func removeIsolatedStore() {
        let fileManager = FileManager.default
        let root = resultURL.deletingLastPathComponent()
        try? fileManager.removeItem(at: root)
        // Den gemeinsamen Oberordner nur entfernen, wenn kein anderer Lauf ihn nutzt.
        let parent = root.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try? fileManager.removeItem(at: parent)
        }
    }
}
