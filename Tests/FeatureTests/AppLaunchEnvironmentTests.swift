import Foundation
import Testing

@testable import FinanceTracker

@Suite("AppLaunchEnvironment")
struct AppLaunchEnvironmentTests {
    @Test("Normale und visuelle UI-Läufe verwenden den Live-Store")
    func normalAndVisualLaunchesUseLiveStore() {
        #expect(AppLaunchEnvironment(arguments: [], configuration: .debug).uiTestStoreURL == nil)
        #expect(AppLaunchEnvironment(arguments: ["-ui-testing-privacy-on"], configuration: .debug).uiTestStoreURL == nil)
        #expect(AppLaunchEnvironment(arguments: ["-ui-testing-window", "1440x900"], configuration: .debug).uiTestStoreURL == nil)
        #expect(AppLaunchEnvironment(arguments: ["-ui-testing-appearance", "dark"], configuration: .debug).uiTestStoreURL == nil)
    }

    @Test("UI-Testing-Empty-Flag verwendet einen isolierten Store")
    func uiTestingEmptyUsesIsolation() {
        let environment = AppLaunchEnvironment(
            arguments: ["-ui-testing-empty"],
            configuration: .debug
        )
        #expect(environment.isUITestingEmptyMode)
        #expect(environment.requiresIsolatedStore)
        #expect(environment.uiTestStoreURL != nil)
    }

    @Test("Storage-Error-Flag wird isoliert und erkannt")
    func uiTestingStorageErrorDetected() {
        let environment = AppLaunchEnvironment(
            arguments: ["-ui-testing-error-storage"],
            configuration: .debug
        )
        #expect(environment.isUITestingStorageErrorMode)
        #expect(environment.requiresIsolatedStore)
        #expect(environment.hasAnyUITestingFlag)
    }

    @Test("Visual-QA-Fenstergröße wird aus gültigem Launch-Argument gelesen")
    func visualQAWindowSizeParsing() {
        let environment = AppLaunchEnvironment(
            arguments: ["-ui-testing-window", "1440x900"],
            configuration: .debug
        )

        #expect(environment.visualQAWindowSize?.width == 1440)
        #expect(environment.visualQAWindowSize?.height == 900)
        #expect(environment.hasAnyUITestingFlag)
    }

    @Test(
        "Ungültige Visual-QA-Fenstergrößen werden abgelehnt",
        arguments: [
            ["-ui-testing-window"],
            ["-ui-testing-window", "1440"],
            ["-ui-testing-window", "breitxhoch"],
            ["-ui-testing-window", "0x900"],
            ["-ui-testing-window", "1440x-1"],
            ["-ui-testing-window", "infx900"]
        ]
    )
    func invalidVisualQAWindowSizes(arguments: [String]) {
        let environment = AppLaunchEnvironment(arguments: arguments, configuration: .debug)
        #expect(environment.visualQAWindowSize == nil)
    }

    @Test("Visual-QA-Appearance akzeptiert nur Light und Dark")
    func visualQAAppearanceParsing() {
        let dark = AppLaunchEnvironment(
            arguments: ["-ui-testing-appearance", "DARK"],
            configuration: .debug
        )
        let invalid = AppLaunchEnvironment(
            arguments: ["-ui-testing-appearance", "system"],
            configuration: .debug
        )

        #expect(dark.visualQAAppearance == "dark")
        #expect(dark.hasAnyUITestingFlag)
        #expect(invalid.visualQAAppearance == nil)
    }
}
