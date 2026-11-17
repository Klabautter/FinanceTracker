import Foundation

/// Wurzelordner für alle Dateien, die die App neben der Datenbank ablegt
/// (Belege, Restore-Sicherheitskopien, Kurs-Cache).
///
/// Isolierte Testläufe (`-ui-testing-empty`, `-ui-testing-error-storage`)
/// bekommen denselben temporären Ordner wie ihr Store. Ohne diese Regel war
/// nur die Datenbank isoliert: eine Wiederherstellung im Testlauf schrieb
/// ihre Sicherheitskopie und Belege in den echten App-Ordner.
enum AppDataDirectory {
    static let isolatingArguments: Set<String> = ["-ui-testing-empty", "-ui-testing-error-storage", "-screenshot-demo"]

    /// Temporärer Ordner eines isolierten Testlaufs, sonst `nil`.
    static func isolatedRoot(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> URL? {
        if let name = smokeTestName(arguments: arguments) {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("FinanceTrackerSmoke", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
        }
        guard arguments.contains(where: isolatingArguments.contains) else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("FinanceTrackerUITests-\(processIdentifier)", isDirectory: true)
    }

    /// Rauchtest der fertigen App (`-smoke-test <name>`): ein vom Skript
    /// vorbereiteter Ordner im temporären Verzeichnis (bei der gesandboxten
    /// App im Container). Nur Buchstaben, Ziffern und Bindestriche, damit
    /// das Argument keinen Pfad außerhalb dieses Ordners treffen kann.
    static func smokeTestName(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let index = arguments.firstIndex(of: "-smoke-test"), arguments.count > index + 1 else { return nil }
        let name = arguments[index + 1]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return nil }
        return name
    }

    /// Unit-Tests laufen im App-Prozess. Ihre Begleitdateien (z. B. der
    /// Kurs-Cache eines Standard-Providers) gehören nicht in den echten
    /// App-Ordner.
    static func unitTestRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> URL? {
        guard environment["XCTestConfigurationFilePath"] != nil else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("FinanceTrackerUnitTests-\(processIdentifier)", isDirectory: true)
    }

    /// Wurzelordner der App-Dateien: isoliert im Testlauf, sonst
    /// `Application Support/FinanceTracker`. `nil`, wenn das System keinen
    /// Application-Support-Ordner liefert.
    static func root(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let isolated = isolatedRoot(arguments: arguments) { return isolated }
        if let unitTest = unitTestRoot(environment: environment) { return unitTest }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FinanceTracker", isDirectory: true)
    }
}
