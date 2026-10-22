import XCTest

/// WP20 (§136-137): UI-Performance-Metriken: App-Launch und Hitches.
/// Läuft im UI-Test-Scheme (Debug, unsandboxed Workaround) und misst die
/// echte SwiftUI-Präsentation. Separat vom Korrektheits-Gate (§186).
final class UIPerformanceMetricsUITests: XCTestCase {

    @MainActor
    func testAppLaunchAndHitchesLiveConnection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-privacy-off"]

        let launchOptions = XCTMeasureOptions()
        launchOptions.iterationCount = 3

        // XCTHitchMetric ist erst ab macOS 26 verfügbar.
        if #available(macOS 26.0, *) {
            measure(metrics: [XCTApplicationLaunchMetric(), XCTHitchMetric(application: app)], options: launchOptions) {
                app.launch()
                _ = app.windows.firstMatch.waitForExistence(timeout: 20)
                // Readiness abwarten, damit die Messung die erste vollständige
                // Präsentation enthält.
                _ = app.descendants(matching: .any)["screen-ready-dashboard"].firstMatch.waitForExistence(timeout: 20)
                app.terminate()
            }
        } else {
            measure(metrics: [XCTApplicationLaunchMetric()], options: launchOptions) {
                app.launch()
                _ = app.windows.firstMatch.waitForExistence(timeout: 20)
                _ = app.descendants(matching: .any)["screen-ready-dashboard"].firstMatch.waitForExistence(timeout: 20)
                app.terminate()
            }
        }
    }
}
