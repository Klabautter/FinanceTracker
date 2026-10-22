import Foundation

/// Zentrale Auswertung von Launch Arguments und Build-Konfiguration.
///
/// UI- und Visual-QA-Läufe verwenden grundsätzlich den regulären Live-Store,
/// damit sie dieselben Daten wie die konfigurierte Enable-Banking-Verbindung
/// zeigen. Nur künstliche Leer-/Fehlerzustände erhalten einen isolierten Store:
/// - `-ui-testing-empty`  → garantiert leere Datenbank
/// - `-ui-testing-error-storage` → Storage-Fehler simulieren
/// - `-ui-testing-privacy-on` → Privacy Mode erzwingen
/// - `-screenshot-demo` → nur DEBUG: isolierter Store mit erfundenen
///   Demo-Daten für die README-Screenshots; der Live-Store bleibt unberührt
struct AppLaunchEnvironment: Sendable {
    enum BuildConfiguration: Sendable {
        case debug
        case release
    }

    let arguments: [String]
    let configuration: BuildConfiguration

    init(arguments: [String], configuration: BuildConfiguration) {
        self.arguments = arguments
        self.configuration = configuration
    }

    static var live: AppLaunchEnvironment {
        #if DEBUG
        AppLaunchEnvironment(arguments: ProcessInfo.processInfo.arguments, configuration: .debug)
        #else
        AppLaunchEnvironment(arguments: ProcessInfo.processInfo.arguments, configuration: .release)
        #endif
    }

    var isUITestingEmptyMode: Bool { arguments.contains("-ui-testing-empty") }
    var isUITestingStorageErrorMode: Bool { arguments.contains("-ui-testing-error-storage") }
    var isUITestingPrivacyMode: Bool { arguments.contains("-ui-testing-privacy-on") }
    /// WP1 (§11-12): Explizites OFF: ohne dieses Flag gilt der persistierte
    /// User-Wert, damit Visual QA nicht von vorherigen Privacy-States
    /// kontaminiert wird.
    var isUITestingPrivacyOffMode: Bool { arguments.contains("-ui-testing-privacy-off") }

    /// WP1 (§12): `true` = Privacy erzwingen, `false` = Privacy-Override OFF,
    /// `nil` = persistierter User-Wert.
    var forcedPrivacyHidesAmounts: Bool? {
        if isUITestingPrivacyMode { return true }
        if isUITestingPrivacyOffMode { return false }
        return nil
    }

    var hasAnyUITestingFlag: Bool {
        isUITestingEmptyMode || isUITestingStorageErrorMode
            || isUITestingPrivacyMode || isUITestingPrivacyOffMode
            || arguments.contains("-ui-testing-window")
            || arguments.contains("-ui-testing-appearance")
    }

    var isScreenshotDemoMode: Bool {
        configuration == .debug && arguments.contains("-screenshot-demo")
    }

    var requiresIsolatedStore: Bool {
        isUITestingEmptyMode || isUITestingStorageErrorMode || isScreenshotDemoMode
    }

    /// Leere und fehlerhafte Testzustände laufen gegen einen isolierten
    /// Store-Pfad. Normale UI-/Visual-QA-Läufe lesen dagegen bewusst den
    /// Live-Store mit der eingerichteten Demo-Bankverbindung.
    var uiTestStoreURL: URL? {
        // Eine Quelle für Store UND Begleitdateien (Belege, Sicherheitskopien).
        AppDataDirectory.isolatedRoot(arguments: arguments)?
            .appendingPathComponent("FinanceTracker.store")
    }

    /// Ob beim Start automatisch Demo-Daten geseedet werden dürfen.
    ///
    /// Release-Installationen starten leer; nur explizite UI-Test-Flags
    /// können das Verhalten in beiden Konfigurationen überschreiben.
    /// Visuelle QA (WP36): Fensterrahmen über `-ui-testing-window 980x620`.
    var visualQAWindowSize: CGSize? {
        guard let index = arguments.firstIndex(of: "-ui-testing-window"),
              arguments.count > index + 1 else { return nil }
        let parts = arguments[index + 1].split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width.isFinite, height.isFinite,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Visuelle QA (WP36): Erscheinungsbild über `-ui-testing-appearance dark|light`.
    var visualQAAppearance: String? {
        guard let index = arguments.firstIndex(of: "-ui-testing-appearance"),
              arguments.count > index + 1 else { return nil }
        let value = arguments[index + 1].lowercased()
        return ["dark", "light"].contains(value) ? value : nil
    }

}
