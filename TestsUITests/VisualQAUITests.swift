import XCTest
import AppKit

/// WP3 (§19-26): Visual-QA-Harness.
///
/// Reproduzierbare Fenster-Screenshots statt Full-Screen-Captures:
/// - Nur das FinanceTracker-Zielfenster wird fotografiert (§21).
/// - 3 Fenstergrößen × Light/Dark × alle Screens (§22).
/// - Privacy ON als separate Cases (§23).
/// - Deterministisches Abwarten über Accessibility-Readiness-Identifier
///   `screen-ready-*`; sleep nur als kurze Settling-Zeit danach (§24).
/// - `manifest.json` mit App-Version, Build, macOS-, Xcode-Version,
///   Fenstergröße, Appearance, Privacy, Locale, Timestamp (§25).
///
/// Ausgabe: PNGs + manifest.json unter
/// `TMP/FinanceTrackerVisualQA/` und zusätzlich als xcresult-Attachments
/// (keepAlways, Export via `xcrun xcresulttool export attachments`).
final class VisualQAUITests: XCTestCase {

    private static let bundleID = "de.klabautter.FinanceTracker"

    // MARK: - Harness-Typen (§25)

    private struct QAVariant: Equatable {
        let windowSize: String
        let appearance: String
        let privacy: String

        var prefix: String { "\(windowSize)-\(appearance)-\(privacy)" }
    }

    private struct QAScreen {
        let sidebar: String
        let managementSegment: String?
        let ready: String
        let readyFallback: String?
        let qa: String
    }

    private struct ManifestEntry: Codable {
        let screenshot: String
        let appVersion: String
        let appBuild: String
        let macOSVersion: String
        let xcodeVersion: String
        let windowSize: String
        let actualWindowSize: String?
        let appearance: String
        let privacyState: String
        let locale: String
        let timestamp: String
    }

    private var manifest: [ManifestEntry] = []
    private var currentVariant = QAVariant(
        windowSize: "1240x800",
        appearance: "light",
        privacy: "off"
    )

    override func tearDown() {
        flushManifest()
        super.tearDown()
    }

    // MARK: - Screens (§22)

    private let mainScreens: [QAScreen] = [
        QAScreen(sidebar: "Übersicht", managementSegment: nil, ready: "screen-ready-dashboard", readyFallback: nil, qa: "Dashboard"),
        QAScreen(sidebar: "Transaktionen", managementSegment: nil, ready: "screen-ready-transactions", readyFallback: nil, qa: "Transactions"),
        QAScreen(sidebar: "Analyse", managementSegment: nil, ready: "screen-ready-analytics", readyFallback: nil, qa: "Analytics"),
        QAScreen(sidebar: "Budgets", managementSegment: nil, ready: "screen-ready-budgets", readyFallback: nil, qa: "Budgets"),
        QAScreen(sidebar: "Wiederkehrend", managementSegment: nil, ready: "screen-ready-recurring", readyFallback: nil, qa: "Recurring"),
        QAScreen(sidebar: "Konten & Verbindungen", managementSegment: nil, ready: "screen-ready-accounts", readyFallback: nil, qa: "Accounts"),
        QAScreen(sidebar: "Kategorien & Regeln", managementSegment: nil, ready: "screen-ready-categories", readyFallback: nil, qa: "Categories"),
        QAScreen(sidebar: "Kategorien & Regeln", managementSegment: "Tags", ready: "screen-ready-tags", readyFallback: nil, qa: "Tags"),
        QAScreen(sidebar: "Sammlungen", managementSegment: nil, ready: "screen-ready-pockets", readyFallback: nil, qa: "Pockets")
    ]

    // MARK: - Matrix-Tests (§22)

    @MainActor
    func testCaptureWindowSizeAndAppearanceMatrix() {
        let windows = ["980x620", "1240x800", "1440x900"]
        let appearances = ["light", "dark"]

        for appearance in appearances {
            for window in windows {
                let variant = QAVariant(windowSize: window, appearance: appearance, privacy: "off")
                captureAllScreens(variant: variant, includeDetails: window == "1240x800")
            }
        }
    }

    /// WP3 (§23): Privacy ON separat, normale Screens bleiben unmaskiert,
    /// damit Betrags-Clipping geprüft werden kann.
    @MainActor
    func testCapturePrivacyOnScreens() {
        let variant = QAVariant(windowSize: "1240x800", appearance: "light", privacy: "on")

        let app = launchApp(variant: variant)
        defer { app.terminate() }

        for screen in mainScreens.prefix(3) {
            guard visit(app, screen: screen) else { continue }
            capture(app, name: screen.qa)
        }

        // Command Palette bei Privacy ON.
        captureCommandPalette(app)
    }

    /// Kurzer Smoke aller Screens in einer Variante (schneller Durchlauf).
    @MainActor
    func testCaptureAllScreens() {
        let variant = QAVariant(windowSize: "1240x800", appearance: "dark", privacy: "off")
        captureAllScreens(variant: variant, includeDetails: true)
    }

    @MainActor
    func testCapturePockets() {
        let variant = QAVariant(windowSize: "1240x800", appearance: "light", privacy: "off")
        currentVariant = variant
        let app = launchApp(variant: variant)
        defer { app.terminate() }

        let pockets = mainScreens.first { $0.qa == "Pockets" }!
        guard visit(app, screen: pockets) else { return }
        capture(app, name: pockets.qa)
    }

    /// README-Screenshots: englische Oberfläche mit erfundenen Demo-Daten
    /// in einem isolierten Store (`-screenshot-demo`), der Live-Store
    /// bleibt unberührt.
    @MainActor
    func testCaptureReadmeScreenshots() {
        for appearance in ["light", "dark"] {
            let variant = QAVariant(windowSize: "1280x800", appearance: appearance, privacy: "off")
            let app = launchApp(
                variant: variant,
                dataMode: "-screenshot-demo",
                extraArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            )
            defer { app.terminate() }

            // ⌘1…⌘5 folgen der Seitenleiste: Übersicht, Transaktionen,
            // Analyse, Budgets, Wiederkehrend.
            let screens = [
                ("1", "screen-ready-dashboard", "Overview"),
                ("2", "screen-ready-transactions", "Transactions"),
                ("3", "screen-ready-analytics", "Analytics"),
                ("4", "screen-ready-budgets", "Budgets"),
                ("5", "screen-ready-recurring", "Recurring")
            ]
            for (key, ready, name) in screens {
                app.typeKey(key, modifierFlags: .command)
                let readyElement = app.descendants(matching: .any)[ready].firstMatch
                XCTAssertTrue(readyElement.waitForExistence(timeout: 20), "Readiness-Signal '\(ready)' fehlt")
                guard readyElement.exists else { continue }
                settle()
                capture(app, name: "readme-\(name)")
            }
        }
    }

    @MainActor
    func testCaptureEmptyFirstRun() {
        let variant = QAVariant(windowSize: "1240x800", appearance: "light", privacy: "off")
        let app = launchApp(variant: variant, dataMode: "-ui-testing-empty")
        defer { app.terminate() }

        let ready = app.descendants(matching: .any)["screen-ready-dashboard"].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "Leerer First Run wurde nicht bereit")
        guard ready.exists else { return }
        settle()
        capture(app, name: "FirstRun-EmptyDashboard")

        guard visit(app, screen: mainScreens[5]) else { return }
        capture(app, name: "FirstRun-EmptyAccounts")
    }

    @MainActor
    func testWindowLaunchArgumentControlsActualFrame() {
        let variant = QAVariant(windowSize: "1440x900", appearance: "light", privacy: "off")
        let app = launchApp(variant: variant, dataMode: "-ui-testing-empty")
        defer { app.terminate() }

        assertWindowFrame(app.windows.firstMatch, matches: variant)
    }

    @MainActor
    private func captureAllScreens(variant: QAVariant, includeDetails: Bool) {
        currentVariant = variant
        let app = launchApp(variant: variant)
        defer { app.terminate() }

        for screen in mainScreens {
            guard visit(app, screen: screen) else { continue }
            capture(app, name: screen.qa)
        }

        guard includeDetails else { return }

        // Transaction Detail (Inspector über Zeilen-Tap).
        guard visit(app, screen: mainScreens[1]) else { return }
        let merchant = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-'"))
            .firstMatch
        XCTAssertTrue(
            merchant.waitForExistence(timeout: 10),
            "Keine Transaktion aus der verbundenen Datenquelle gefunden"
        )
        merchant.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let detailTitle = app.descendants(matching: .any)["transaction-detail-content"].firstMatch
        XCTAssertTrue(
            detailTitle.waitForExistence(timeout: 10),
            "Transaction Detail (Inspector) nicht geöffnet"
        )
        guard detailTitle.exists else { return }
        settle()
        capture(app, name: "TransactionDetail")

        // Command Palette (⌘K).
        captureCommandPalette(app)

        // Budget Detail im nativen Master-Detail-Inspector.
        guard visit(app, screen: mainScreens[3]) else { return }
        let budgetRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'budget-row-'"))
            .firstMatch
        guard ensureVisible(app, budgetRow, name: "Budget aus dem verbundenen Datenstand") else { return }
        openWithFallback(app, budgetRow) { self.budgetDetailVisible(app) }
        let didOpenBudgetDetail = budgetDetailVisible(app)
        XCTAssertTrue(
            didOpenBudgetDetail,
            "Budget-Detail-Inspector nicht geöffnet. Elementbaum:\n\(app.debugDescription.prefix(3000))"
        )
        guard didOpenBudgetDetail else { return }
        settle()
        capture(app, name: "BudgetDetail")

        // Fixkosten-Detail im nativen Master-Detail-Inspector.
        guard visit(app, screen: mainScreens[4]) else { return }
        let commitmentRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'commitment-row-'"))
            .firstMatch
        guard ensureVisible(app, commitmentRow, name: "Zahlungsplan aus dem verbundenen Datenstand") else { return }
        openWithFallback(app, commitmentRow) { self.recurringDetailVisible(app) }
        let didOpenRecurringDetail = recurringDetailVisible(app)
        XCTAssertTrue(
            didOpenRecurringDetail,
            "Fixkosten-Detail-Inspector nicht geöffnet. Elementbaum:\n\(app.debugDescription.prefix(3000))"
        )
        guard didOpenRecurringDetail else { return }
        settle()
        capture(app, name: "RecurringDetail")

        captureSupplementalFlows(app)
    }

    @MainActor
    private func captureSupplementalFlows(_ app: XCUIApplication) {
        guard visit(app, screen: mainScreens[1]) else { return }
        let addTransaction = app.buttons["transaction-add-button"].firstMatch
        XCTAssertTrue(addTransaction.waitForExistence(timeout: 10), "Neue-Transaktion-Aktion fehlt")
        guard addTransaction.exists else { return }
        addTransaction.tap()
        let transactionTitle = app.staticTexts["Neue Transaktion"].firstMatch
        XCTAssertTrue(transactionTitle.waitForExistence(timeout: 10), "Neue-Transaktion-Sheet wurde nicht geöffnet")
        guard transactionTitle.exists else { return }
        settle()
        capture(app, name: "AddTransaction")
        let cancelTransaction = app.buttons["Abbrechen"].firstMatch
        cancelTransaction.tap()
        XCTAssertTrue(transactionTitle.waitForNonExistence(timeout: 10), "Neue-Transaktion-Sheet wurde nicht geschlossen")

        guard visit(app, screen: mainScreens[5]) else { return }
        let addDataSource = app.buttons["account-add-source-button"].firstMatch
        XCTAssertTrue(addDataSource.waitForExistence(timeout: 10), "Datenquelle-hinzufügen-Aktion fehlt")
        guard addDataSource.exists else { return }
        addDataSource.tap()
        let bankSource = app.buttons["Bankkonto verbinden"].firstMatch
        XCTAssertTrue(bankSource.waitForExistence(timeout: 10), "Datenquellen-Auswahl wurde nicht geöffnet")
        guard bankSource.exists else { return }
        settle()
        capture(app, name: "AddDataSource")

        let importSource = app.buttons["CSV / Excel importieren"].firstMatch
        XCTAssertTrue(importSource.waitForExistence(timeout: 5), "Import-Aktion fehlt in der Datenquellen-Auswahl")
        guard importSource.exists else { return }
        importSource.tap()
        let filePicker = app.buttons["CSV- oder Excel-Datei auswählen…"].firstMatch
        XCTAssertTrue(filePicker.waitForExistence(timeout: 10), "Import-Screen wurde nicht geöffnet")
        guard filePicker.exists else { return }
        settle()
        capture(app, name: "Import")
        let importDone = app.buttons["Fertig"].firstMatch
        importDone.tap()
        XCTAssertTrue(filePicker.waitForNonExistence(timeout: 10), "Import-Screen wurde nicht geschlossen")

        guard visit(app, screen: mainScreens[0]) else { return }
        let review = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[cd] 'Prüfliste'")
        ).firstMatch
        guard ensureVisible(app, review, name: "Prüflisten-Aktion im verbundenen Dashboard") else { return }
        let reviewList = app.descendants(matching: .any)["review-queue-list"].firstMatch
        openWithFallback(app, review) {
            reviewList.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(reviewList.waitForExistence(timeout: 10), "Prüfliste hat keine geladenen Einträge dargestellt")
        guard reviewList.exists else { return }
        settle()
        capture(app, name: "Review")
        let reviewDone = app.buttons["Fertig"].firstMatch
        reviewDone.tap()
        XCTAssertTrue(reviewList.waitForNonExistence(timeout: 10), "Prüfliste wurde nicht geschlossen")

        captureSettings(app)
    }

    @MainActor
    private func captureSettings(_ app: XCUIApplication) {
        let settingsNavigation = app.descendants(matching: .any)["sidebar-Einstellungen"].firstMatch
        XCTAssertTrue(settingsNavigation.waitForExistence(timeout: 10), "Einstellungen fehlen in der Navigation")
        guard settingsNavigation.exists else { return }
        settingsNavigation.tap()

        let settingsMarker = app.staticTexts["Basiswährung"].firstMatch
        XCTAssertTrue(settingsMarker.waitForExistence(timeout: 10), "Einstellungsfenster wurde nicht geöffnet")
        guard settingsMarker.exists else { return }

        let settingsWindow = (0..<app.windows.count)
            .map { app.windows.element(boundBy: $0) }
            .first { $0.staticTexts["Basiswährung"].exists }
        guard let settingsWindow else {
            XCTFail("Einstellungsinhalt konnte keinem Fenster zugeordnet werden")
            return
        }
        settle()
        capture(app, window: settingsWindow, name: "Settings")
        settingsWindow.typeKey("w", modifierFlags: .command)
    }

    /// Bewährtes Muster: Tap an der Frame-Position des Elements
    /// relativ zum Fenster (element-relatie Koordinaten sind auf macOS bei
    /// kombinierten Elementen unzuverlässig). A11y-`tap()` zuerst.
    @MainActor
    private func openWithFallback(_ app: XCUIApplication, _ element: XCUIElement, until condition: () -> Bool) {
        element.tap()
        if condition() { return }
        tapAtElementFrame(app, element)
        _ = condition()
    }

    /// Sheet-Content-Checks, scoped auf das Sheet (macOS 26: Whole-Tree-
    /// Prädikate können in UI-Query-Timeouts laufen).

    @MainActor
    private func budgetDetailVisible(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'budget-detail-'"))
            .firstMatch.exists
    }

    @MainActor
    private func recurringDetailVisible(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'recurring-inspector-'"))
            .firstMatch.exists
    }

    @MainActor
    private func tapAtElementFrame(_ app: XCUIApplication, _ element: XCUIElement) {
        let elementFrame = element.frame
        guard elementFrame.midX.isFinite, elementFrame.midY.isFinite, !elementFrame.isEmpty else { return }
        let windowFrame = app.windows.firstMatch.frame
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(
                dx: elementFrame.midX - windowFrame.minX,
                dy: elementFrame.midY - windowFrame.minY
            ))
            .tap()
    }

    /// Scrollt das Detail-Area, bis das Element existiert (List-Virtualisierung).
    @MainActor
    private func ensureVisible(_ app: XCUIApplication, _ element: XCUIElement, name: String) -> Bool {
        if element.waitForExistence(timeout: 10) { return true }
        let windowFrame = app.windows.firstMatch.frame
        let point = CGPoint(x: windowFrame.midX + windowFrame.width * 0.15, y: windowFrame.midY)
        for _ in 0..<5 {
            scrollWheel(at: point, lines: 3)
            if element.exists { return true }
        }
        XCTFail("\(name) nicht auffindbar (auch nach Scroll). Elementbaum:\n\(app.debugDescription.prefix(3000))")
        return false
    }

    /// Scroll-Wheel-Event an Bildschirmkoordinate (zuverlässiger Scroll).
    @MainActor
    private func scrollWheel(at point: CGPoint, lines: Int) {
        for _ in 0..<max(1, lines / 3) {
            let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: Int32(-3),
                wheel2: 0,
                wheel3: 0
            )
            event?.location = point
            event?.post(tap: .cghidEventTap)
            usleep(120_000)
        }
    }

    @MainActor
    private func captureCommandPalette(_ app: XCUIApplication) {
        app.typeKey("k", modifierFlags: .command)
        let searchTitle = app.staticTexts["Suchen"].firstMatch
        XCTAssertTrue(
            searchTitle.waitForExistence(timeout: 10),
            "Command Palette nicht über ⌘K geöffnet"
        )
        guard searchTitle.exists else { return }
        settle()
        capture(app, name: "CommandPalette")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Harness-Helper (§21/§24)

    @MainActor
    private func launchApp(
        variant: QAVariant,
        dataMode: String? = nil,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        currentVariant = variant
        for running in NSWorkspace.shared.runningApplications
        where running.bundleIdentifier == Self.bundleID {
            running.forceTerminate()
        }
        let terminationDeadline = Date().addingTimeInterval(10)
        while Date() < terminationDeadline,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == Self.bundleID }) {
            Thread.sleep(forTimeInterval: 0.2)
        }

        let app = XCUIApplication(bundleIdentifier: Self.bundleID)
        app.launchArguments = [
            "-ui-testing-privacy-\(variant.privacy)",
            "-ui-testing-window", variant.windowSize,
            "-ui-testing-appearance", variant.appearance
        ]
        if let dataMode {
            app.launchArguments.insert(dataMode, at: 0)
        }
        app.launchArguments += extraArguments
        UITestLaunch.launchAndAwaitWindow(app, windowTimeout: 20)
        app.activate()
        assertWindowFrame(app.windows.firstMatch, matches: variant)
        return app
    }

    @MainActor
    @discardableResult
    private func visit(_ app: XCUIApplication, screen: QAScreen) -> Bool {
        let item = app.descendants(matching: .any)["sidebar-\(screen.sidebar)"].firstMatch
        guard item.waitForExistence(timeout: 15), item.isHittable else {
            XCTFail("Sidebar '\(screen.sidebar)' nicht gefunden")
            return false
        }
        item.tap()

        if let segment = screen.managementSegment {
            guard tapManagementSegment(app, title: segment) else { return false }
        }

        // §24: Readiness deterministisch abwarten, kein sleep als primäre
        // Synchronisation. Exakte Identifier-Queries (keine teuren
        // Whole-Tree-Prädikate).
        let ready = app.descendants(matching: .any)[screen.ready].firstMatch
        let exists = ready.waitForExistence(timeout: 20)
        if exists {
            settle()
            return true
        }
        if let fallback = screen.readyFallback,
           app.descendants(matching: .any)[fallback].firstMatch.waitForExistence(timeout: 5) {
            settle()
            return true
        }
        XCTFail("Readiness-Signal '\(screen.ready)' fehlt")
        return false
    }

    @MainActor
    private func tapManagementSegment(_ app: XCUIApplication, title: String) -> Bool {
        let candidates = [
            app.radioButtons[title].firstMatch,
            app.buttons[title].firstMatch
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 3) {
            if candidate.isHittable {
                candidate.tap()
                return true
            }
        }
        XCTFail("Verwaltungssegment '\(title)' nicht gefunden oder nicht bedienbar")
        return false
    }

    @MainActor
    private func assertWindowFrame(_ window: XCUIElement, matches variant: QAVariant) {
        let dimensions = variant.windowSize.split(separator: "x").compactMap {
            Double($0).map { CGFloat($0) }
        }
        guard dimensions.count == 2 else {
            XCTFail("Ungültige erwartete Fenstergröße '\(variant.windowSize)'")
            return
        }

        let expectedWidth = dimensions[0]
        let expectedContentHeight = dimensions[1]
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let frame = window.frame
            if abs(frame.width - expectedWidth) <= 2,
               frame.height >= expectedContentHeight - 2,
               frame.height <= expectedContentHeight + 80 {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let frame = window.frame
        XCTAssertEqual(frame.width, expectedWidth, accuracy: 2, "Launch-Argument wurde nicht auf die Fensterbreite angewendet")
        XCTAssertGreaterThanOrEqual(frame.height, expectedContentHeight - 2, "Fenster ist niedriger als die angeforderte Content-Höhe")
        XCTAssertLessThanOrEqual(frame.height, expectedContentHeight + 80, "Fensterhöhe weicht stärker als die macOS-Titelleiste ab")
    }

    /// Kurze visuelle Settling-Zeit NACH dem echten Readiness-Signal (§24).
    @MainActor
    private func settle() {
        usleep(600_000)
    }

    // MARK: - Screenshot + Manifest (§21/§25)

    @MainActor
    private func capture(
        _ app: XCUIApplication,
        window: XCUIElement? = nil,
        name: String
    ) {
        let window = window ?? app.windows.firstMatch
        XCTAssertTrue(window.exists, "Zielfenster für '\(name)' nicht vorhanden")
        guard window.exists else { return }

        // §21: Nur das Zielfenster, kein Full-Screen.
        let screenshot = window.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "QA-\(currentVariant.prefix)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let fileName = "\(currentVariant.prefix)-\(name).png"
        guard writeFile(screenshot: screenshot, fileName: fileName) else { return }
        manifest.append(makeEntry(screenshot: fileName, window: window))
    }

    @MainActor
    private func makeEntry(screenshot: String, window: XCUIElement) -> ManifestEntry {
        var appVersion = "unknown"
        var appBuild = "unknown"
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Self.bundleID
        }), let bundleURL = running.bundleURL, let bundle = Bundle(url: bundleURL) {
            appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            appBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return ManifestEntry(
            screenshot: screenshot,
            appVersion: appVersion,
            appBuild: appBuild,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            xcodeVersion: ProcessInfo.processInfo.environment["XCODE_VERSION_ACTUAL"] ?? "unknown",
            windowSize: currentVariant.windowSize,
            actualWindowSize: formattedSize(window.frame.size),
            appearance: currentVariant.appearance,
            privacyState: currentVariant.privacy,
            locale: Locale.current.identifier,
            timestamp: formatter.string(from: Date())
        )
    }

    private func formattedSize(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    @discardableResult
    @MainActor
    private func writeFile(screenshot: XCUIScreenshot, fileName: String) -> Bool {
        let directory = outputDirectory()
        let url = directory.appendingPathComponent(fileName)
        do {
            try screenshot.pngRepresentation.write(to: url)
            return true
        } catch {
            // Datei-Ausgabe ist Sekundärkanal; xcresult-Attachment ist
            // verbindlich. Fehler darf den Test nicht brechen.
            print("VisualQA: PNG \(fileName) konnte nicht geschrieben werden: \(error)")
            return false
        }
    }

    private func flushManifest() {
        guard !manifest.isEmpty else { return }
        let directory = outputDirectory()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestURL = directory.appendingPathComponent("manifest.json")
            var combined: [ManifestEntry] = []
            if let existingData = try? Data(contentsOf: manifestURL) {
                combined = (try? JSONDecoder().decode([ManifestEntry].self, from: existingData)) ?? []
            }
            combined.removeAll {
                !$0.screenshot.hasSuffix(".png")
                    || !FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent($0.screenshot).path
                    )
            }
            let newScreenshotNames = Set(manifest.map(\.screenshot))
            combined.removeAll { newScreenshotNames.contains($0.screenshot) }
            combined.append(contentsOf: manifest)
            combined.sort { $0.screenshot < $1.screenshot }
            let data = try encoder.encode(combined)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            print("VisualQA: manifest.json konnte nicht geschrieben werden: \(error)")
        }
        manifest = []
    }

    private func outputDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinanceTrackerVisualQA", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
