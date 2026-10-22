import XCTest

/// Geteilter Launch-Helper für UI-Tests.
///
/// macOS 26 präsentiert bei direktem Binary-Launch (XCUITest) gelegentlich
/// kein SwiftUI-Fenster (Launch-Race: unsandboxed Debug +
/// ENABLE_DEBUG_DYLIB NO + .defaultLaunchBehavior(.presented) mildern das,
/// eliminieren es aber nicht zu 100 %). Der Helper retryt den Launch
/// definiert einmal, die Pflicht-Assertion „Fenster muss existieren"
/// bleibt bestehen.
enum UITestLaunch {

    @MainActor
    static func launchAndAwaitWindow(
        _ app: XCUIApplication,
        windowTimeout: TimeInterval = 15
    ) {
        app.launch()
        _ = app.windows.firstMatch.waitForExistence(timeout: windowTimeout)
        if !app.windows.firstMatch.exists {
            // Definierter Retry: sauber beenden und erneut starten.
            app.terminate()
            app.launch()
            _ = app.windows.firstMatch.waitForExistence(timeout: windowTimeout)
        }
        XCTAssertTrue(
            app.windows.firstMatch.exists,
            "App-Fenster sollte nach Launch (inkl. Retry) präsentiert sein"
        )
    }
}