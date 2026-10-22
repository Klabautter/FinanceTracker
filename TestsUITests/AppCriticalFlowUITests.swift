import XCTest
import AppKit

/// Kritische Navigation-Flows mit strikten Assertions.
///
/// Regel (Roadmap WP2): Pflicht-UI darf nicht still übersprungen werden.
/// Normale Flows lesen den Live-Store mit der eingerichteten
/// Enable-Banking-Mock-Verbindung. Nur künstliche Zustände sind isoliert:
/// - `-ui-testing-empty` → garantiert leere Datenbank
/// - `-ui-testing-error-storage` → simulierter Storage-Fehler
///
/// Wichtig: Der Debug-Build läuft ohne App Sandbox (siehe project.yml).
/// Der Start erfolgt über LaunchServices, direkte Binary-Launches erhalten
/// unter macOS 26 nicht zuverlässig ein SwiftUI-Fenster.
final class AppCriticalFlowUITests: XCTestCase {

    private static let bundleID = "de.klabautter.FinanceTracker"

    private var app: XCUIApplication!

    override func tearDown() {
        let launchedApp = app
        app = nil
        MainActor.assumeIsolated {
            launchedApp?.terminate()
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Scroll-Wheel-Event an Bildschirmkoordinate (zuverlässiger Scroll).
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

    /// Startet die App über den nativen XCUITest-Launch.
    ///
    /// Der Debug-Build läuft ohne App Sandbox (siehe project.yml), sodass der
    /// Standard-Launch unter macOS 26 ein SwiftUI-Fenster präsentiert.
    /// `launchArguments` übergibt die deterministischen Launch-States
    /// zuverlässig an den App-Prozess, im Gegensatz zu `open --args` +
    /// Attach, bei dem LaunchServices eine Instanz ohne Arguments starten
    /// kann (Race zwischen forceTerminate und open).
    @MainActor
    @discardableResult
    private func launchApp(arguments: [String] = []) -> XCUIApplication {
        // Alte Instanzen sauber beenden und das Ende abwarten.
        for running in NSWorkspace.shared.runningApplications
        where running.bundleIdentifier == Self.bundleID {
            running.forceTerminate()
        }
        let killDeadline = Date().addingTimeInterval(10)
        while Date() < killDeadline,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == Self.bundleID }) {
            Thread.sleep(forTimeInterval: 0.2)
        }

        let app = XCUIApplication(bundleIdentifier: Self.bundleID)
        app.launchArguments = arguments
        UITestLaunch.launchAndAwaitWindow(app)
        self.app = app
        return app
    }

    @MainActor
    private func sidebarItem(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        // Deterministischer Matcher: Die Sidebar-Items führen den
        // accessibilityIdentifier "sidebar-<Titel>" (siehe MacRootView).
        // Ein nackter Titel-Lookup würde z. B. die Dashboard-Karte
        // "Budgets" statt der Sidebar-Row treffen.
        app.descendants(matching: .any)["sidebar-\(title)"].firstMatch
    }

    /// Öffnet einen Sidebar-Eintrag und schlägt fehl, wenn er fehlt.
    @MainActor
    private func openSection(_ app: XCUIApplication, _ title: String) {
        let item = sidebarItem(app, title)
        guard item.waitForExistence(timeout: 20) else {
            XCTFail("Pflicht-Navigation '\(title)' fehlt in der Sidebar. Elementbaum:\n\(app.debugDescription.prefix(3000))")
            return
        }
        item.tap()
    }

    /// Verwaltungsseiten sind direkte Ziele in der Sidebar.
    @MainActor
    private func openManagementSection(_ app: XCUIApplication, _ title: String) {
        openSection(app, title == "Kategorien" ? "Kategorien & Regeln" : title)
    }

    @MainActor
    private func assertExists(_ element: XCUIElement, _ description: String, timeout: TimeInterval = 5) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Erwartetes UI nicht gefunden: \(description)"
        )
    }

    @MainActor
    private func firstTransactionRowAnchor(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-'"))
            .firstMatch
    }

    // MARK: - Privacy Mode (WP1)

    @MainActor
    func testPrivacyOnMasksDashboardAmounts() {
        let app = launchApp(arguments: ["-ui-testing-privacy-on"])

        // Maskierte Beträge sind sichtbar.
        let mask = app.staticTexts["•••"].firstMatch
        assertExists(mask, "Maskierte Beträge auf dem Dashboard")

        // VoiceOver-Labels dürfen den Betrag nicht weiterlesen: Die Row-
        // Accessibility läuft über PrivacyAwareMoney ("Betrag verborgen").
        let hiddenLabel = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Betrag verborgen'")
        ).firstMatch
        assertExists(hiddenLabel, "Privacy-sicheres Accessibility-Label auf Dashboard-Rows")
    }

    @MainActor
    func testPrivacyOnMasksTransactionRows() {
        let app = launchApp(arguments: ["-ui-testing-privacy-on"])
        openSection(app, "Transaktionen")

        // SwiftUI-Tables exponieren Zellinhalte als value: Die Betrags-Spalte
        // liefert das Privacy-A11y-Statement statt des echten Betrags.
        let hiddenValue = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == 'Betrag verborgen' OR label == 'Betrag verborgen'"))
            .firstMatch
        assertExists(hiddenValue, "Privacy-sichere Betrags-Zelle in der Transaktions-Tabelle", timeout: 10)
    }

    // MARK: - Deterministische Launch States

    @MainActor
    func testStorageErrorLaunchShowsRecoveryScreen() {
        let app = launchApp(arguments: ["-ui-testing-error-storage"])

        let recovery = app.staticTexts["Lokale Daten konnten nicht geöffnet werden"]
        assertExists(recovery, "Storage-Recovery-Screen bei -ui-testing-error-storage")

        let retryButton = app.buttons["Erneut versuchen"]
        assertExists(retryButton, "Wiederholen-Aktion im Recovery-Screen")
    }

    @MainActor
    func testEmptyLaunchShowsNoAccountsAnywhere() {
        let app = launchApp(arguments: ["-ui-testing-empty"])
        openSection(app, "Konten & Verbindungen")

        let emptyTitle = app.staticTexts["Noch keine Konten"]
        assertExists(emptyTitle, "Empty State der Konten bei leerer Datenbank")

        let addSourceButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Datenquelle'")
        ).firstMatch
        assertExists(addSourceButton, "Datenquelle-hinzufügen-Aktion im Empty State")
    }

    // MARK: - Add Data Source Flows

    @MainActor
    func testAddDataSourceSheetShowsCompleteSourcePicker() {
        let app = launchApp()
        openSection(app, "Konten & Verbindungen")

        openAddDataSourceSheet(app)

        // Konsolidierter Picker (MacUX-Audit „Import"): ether.fi/MetaMask
        // laufen über die Auto-Erkennung von „CSV / Excel importieren"
        // es gibt keine eigenen Provider-Einträge mehr.
        assertExists(app.buttons["Bankkonto verbinden"], "Eintrag Bankkonto")
        assertExists(app.buttons["CSV / Excel importieren"], "Eintrag CSV/Excel")

        closeAddDataSourceSheet(app)
    }

    @MainActor
    func testAddDataSourceBankFlowNavigatesForwardAndBack() {
        let app = launchApp()
        openSection(app, "Konten & Verbindungen")

        openAddDataSourceSheet(app)
        tapButton(app, "Bankkonto verbinden")

        // Mit gespeicherten Mock-Credentials springt der Flow direkt zur
        // Bankauswahl; ohne Credentials zeigt er die Zugangsdaten-Form.
        let credentialsHeader = app.staticTexts["Enable Banking Zugangsdaten"]
        let countryPicker = app.popUpButtons["Land"].firstMatch
        XCTAssertTrue(
            credentialsHeader.waitForExistence(timeout: 10) || countryPicker.waitForExistence(timeout: 10),
            "Bank-Flow zeigt weder Zugangsdaten noch die Enable-Banking-Bankauswahl"
        )

        // Expliziter Zurück-Button (DoD Navigation: Jeder Push kann zurück)
        let backButton = app.buttons["Zurück"]
        assertExists(backButton, "Zurück-Button im Bank-Flow", timeout: 5)
        backButton.tap()

        assertExists(
            app.buttons["Bankkonto verbinden"],
            "Rückkehr zum Source Picker nach Back",
            timeout: 10
        )
        closeAddDataSourceSheet(app)
    }

    @MainActor
    func testAddDataSourceCSVFlowOpensAndCloses() {
        let app = launchApp()
        openSection(app, "Konten & Verbindungen")

        openAddDataSourceSheet(app)
        tapButton(app, "CSV / Excel importieren")

        assertExists(
            app.buttons["CSV- oder Excel-Datei auswählen…"],
            "Import-Bildschirm mit Datei-Auswahl"
        )
        closeAddDataSourceSheetViaDone(app)
    }

    // MARK: - Transactions

    @MainActor
    func testTransactionsDetailAndBack() {
        let app = launchApp()
        openSection(app, "Transaktionen")

        // macOS 26 exponiert SwiftUI-Table-Zeilen nicht als tableRows
        // wir klicken per Koordinate auf den Händler-Text der ersten Zeile
        // (sichere Spalte ohne Menü/Pill-Interaktion).
        let merchantText = firstTransactionRowAnchor(app)
        guard merchantText.waitForExistence(timeout: 20) else {
            XCTFail("Keine Tabellenzeile (Händler-Text) gefunden. Elementbaum:\n\(app.debugDescription.prefix(15000))")
            return
        }
        let rowFrame = merchantText.frame
        guard rowFrame.midX.isFinite, rowFrame.midY.isFinite, !rowFrame.isEmpty else {
            XCTFail("Händler-Text liefert keinen gültigen Frame.")
            return
        }
        let winFrameTxn = app.windows.firstMatch.frame
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: rowFrame.midX - winFrameTxn.minX, dy: rowFrame.midY - winFrameTxn.minY))
            .tap()

        // macOS zeigt das Detail im Inspector (Selection → Detail rechts).
        let detailSection = app.descendants(matching: .any)["transaction-detail-content"].firstMatch
        guard detailSection.waitForExistence(timeout: 10) else {
            XCTFail("Transaction Detail im Inspector nicht gefunden. Elementbaum:\n\(app.debugDescription.prefix(15000))")
            return
        }
    }

    // MARK: - Dashboard

    @MainActor
    func testDashboardTransactionDetailSheetOpenAndClose() {
        let app = launchApp()
        openSection(app, "Übersicht")

        let transaction = app.buttons["dashboard.transactionRow"].firstMatch
        assertExists(transaction, "Buchung in der Übersicht", timeout: 30)
        transaction.tap()

        let detail = app.descendants(matching: .any)["transaction-detail-content"].firstMatch
        assertExists(detail, "Buchungsdetail", timeout: 10)
        let technicalDetails = app.buttons["transaction-technical-details"].firstMatch
        assertExists(technicalDetails, "Technische Details")
        technicalDetails.tap()
        XCTAssertEqual(technicalDetails.value as? String, "Ausgeklappt")
        technicalDetails.tap()
        XCTAssertEqual(technicalDetails.value as? String, "Eingeklappt")
        app.buttons["Fertig"].firstMatch.tap()
        XCTAssertFalse(detail.exists)
    }

    @MainActor
    func testReviewQueueOpenAndClose() {
        let app = launchApp()
        openSection(app, "Übersicht")
        let review = app.buttons["dashboard-review-queue"].firstMatch
        assertExists(review, "Prüfliste im verbundenen Datenstand")
        review.tap()
        let doneButton = app.buttons["Fertig"].firstMatch
        assertExists(doneButton, "Prüfliste mit Fertig-Aktion")
        doneButton.tap()
    }

    // MARK: - Analytics

    @MainActor
    func testAnalyticsFilterControlsPresent() {
        let app = launchApp()
        openSection(app, "Analyse")
        let filter = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Zeitraum & Filter")
        ).firstMatch
        assertExists(filter, "Analysefilter öffnen")
        filter.tap()
        assertExists(
            app.descendants(matching: .any)["Zeitraum für die Analyse"].firstMatch,
            "Zeitraum im Filterdialog"
        )
        app.buttons["Fertig"].firstMatch.tap()
    }

    // MARK: - Budgets

    @MainActor
    func testBudgetAddAndCancel() {
        let app = launchApp()
        openSection(app, "Budgets")

        // macOS exponiert Toolbar-Buttons mit Symbol+Text als AXDescription
        // der accessibilityIdentifier ist der stabile Matcher.
        let addButton = app.buttons["Budget hinzufügen"].firstMatch
        assertExists(addButton, "Budget hinzufügen Aktion")
        addButton.tap()

        let cancelButton = app.buttons["Abbrechen"]
        assertExists(cancelButton, "Abbrechen im Budget-Formular")
        cancelButton.tap()
    }

    // MARK: - Categories

    @MainActor
    func testCategoriesScreenLoads() {
        let app = launchApp()
        openManagementSection(app, "Kategorien")

        // Roadmap #52: Standard-Tab „Kategorien“, Automatisierung getrennt.
        let structureNote = app.staticTexts[
            "Transaktionen werden auf Unterkategorien gebucht; Hauptkategorien fassen zusammen."
        ]
        assertExists(structureNote, "Kategorien-Struktur-Sicht")

        let automationTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Automatisierung'")).firstMatch
        assertExists(automationTab, "Automatisierung-Tab")
        automationTab.tap()

        let rulesHeader = app.staticTexts["Automatische Kategorisierung"]
        assertExists(rulesHeader, "Automatisierungs-Regelbereich")
    }

    // MARK: - Core Sections Smoke (strikt)

    @MainActor
    func testAllCoreSidebarSectionsExistAndRespond() {
        let app = launchApp()

        let sidebarSections = [
            ("Übersicht", "screen-ready-dashboard"),
            ("Transaktionen", "screen-ready-transactions"),
            ("Analyse", "screen-ready-analytics"),
            ("Budgets", "screen-ready-budgets"),
            ("Sammlungen", "screen-ready-pockets"),
            ("Wiederkehrend", "screen-ready-recurring"),
            ("Konten & Verbindungen", "screen-ready-accounts")
        ]
        for (section, readyIdentifier) in sidebarSections {
            let item = sidebarItem(app, section)
            XCTAssertTrue(item.waitForExistence(timeout: 5), "Sidebar-Sektion '\(section)' fehlt")
            item.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)[readyIdentifier].firstMatch.waitForExistence(timeout: 20),
                "Sektionsinhalt '\(section)' wurde nicht bereit"
            )
        }

        openManagementSection(app, "Kategorien")
        assertExists(
            app.descendants(matching: .any)["screen-ready-categories"].firstMatch,
            "Kategorien & Regeln",
            timeout: 20
        )
        // Tags sind ein Segment in „Kategorien & Regeln", kein Sidebar-Eintrag.
        let tagsTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Tags'")).firstMatch
        assertExists(tagsTab, "Tags-Segment")
        tagsTab.tap()
        assertExists(
            app.descendants(matching: .any)["screen-ready-tags"].firstMatch,
            "Tags",
            timeout: 20
        )
    }

    // MARK: - Private Sheet Helpers

    @MainActor
    private func openAddDataSourceSheet(_ app: XCUIApplication) {
        let addButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Datenquelle'")
        ).firstMatch
        assertExists(addButton, "Datenquelle hinzufügen Button")
        addButton.tap()
        assertExists(
            app.buttons["Bankkonto verbinden"],
            "Geöffnetes Add-Data-Source-Sheet"
        )
    }

    @MainActor
    private func closeAddDataSourceSheet(_ app: XCUIApplication) {
        let cancelButton = app.buttons["Abbrechen"].firstMatch
        assertExists(cancelButton, "Abbrechen im Add-Data-Source-Sheet")
        cancelButton.tap()
    }

    @MainActor
    private func closeAddDataSourceSheetViaDone(_ app: XCUIApplication) {
        let doneButton = app.buttons["Fertig"].firstMatch
        assertExists(doneButton, "Fertig im Import-Flow")
        doneButton.tap()
    }

    @MainActor
    private func tapButton(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons[label].firstMatch
        assertExists(button, "Button '\(label)'")
        button.tap()
    }
}
