import XCTest

/// WP-MacUX: Scroll-Hitch-Messung der Transaktions-Tabelle.
/// Baseline VOR den Render-Fixes, dann Vergleich danach (§180: Kein
/// Performance-Urteil ohne Messung).
final class TransactionScrollPerfUITests: XCTestCase {

    @MainActor
    func testTransactionsScrollHitches() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("XCTHitchMetric benötigt macOS 26")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-privacy-off"]
        app.launch()
        _ = app.windows.firstMatch.waitForExistence(timeout: 20)

        // Zur Transaktions-Tabelle navigieren.
        let transactionsItem = app.descendants(matching: .any)["sidebar-Transaktionen"].firstMatch
        XCTAssertTrue(transactionsItem.waitForExistence(timeout: 15))
        transactionsItem.tap()
        _ = app.descendants(matching: .any)["screen-ready-transactions"].firstMatch.waitForExistence(timeout: 20)

        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        measure(metrics: [XCTHitchMetric(application: app)], options: measureOptions) {
            // Mehrere Scroll-Zyklen über die gesamte Tabelle.
            for _ in 0..<6 {
                app.windows.firstMatch.typeKey(.pageDown, modifierFlags: [])
                usleep(250_000)
            }
            for _ in 0..<6 {
                app.windows.firstMatch.typeKey(.pageUp, modifierFlags: [])
                usleep(250_000)
            }
        }
        app.terminate()
    }
}
