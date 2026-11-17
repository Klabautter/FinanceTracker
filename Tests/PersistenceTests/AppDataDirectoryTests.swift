import Foundation
import Testing

@testable import FinanceTracker

@Suite("App-Datenordner: Isolation im Testmodus")
struct AppDataDirectoryTests {
    @Test("Isolierte Testläufe bekommen einen temporären Ordner, für Store und Begleitdateien denselben")
    func isolatedRunsUseTemporaryRoot() throws {
        for flag in ["-ui-testing-empty", "-ui-testing-error-storage"] {
            let arguments = ["FinanceTracker", flag]
            let isolated = try #require(AppDataDirectory.isolatedRoot(arguments: arguments, processIdentifier: 4711))
            #expect(isolated.lastPathComponent == "FinanceTrackerUITests-4711")
            #expect(isolated.path.hasPrefix(FileManager.default.temporaryDirectory.path))

            let root = try #require(AppDataDirectory.root(arguments: arguments))
            #expect(!root.path.contains("Application Support"))

            let environment = AppLaunchEnvironment(arguments: arguments, configuration: .debug)
            let storeURL = try #require(environment.uiTestStoreURL)
            #expect(storeURL.deletingLastPathComponent().path == root.path)
        }
    }

    @Test("Normale Läufe nutzen den App-Ordner unter Application Support")
    func regularRunsUseApplicationSupport() throws {
        let arguments = ["FinanceTracker", "-ui-testing-privacy-on"]
        #expect(AppDataDirectory.isolatedRoot(arguments: arguments) == nil)
        let root = try #require(AppDataDirectory.root(arguments: arguments, environment: [:]))
        #expect(root.lastPathComponent == "FinanceTracker")
        #expect(root.path.contains("Application Support"))
        #expect(AppLaunchEnvironment(arguments: arguments, configuration: .debug).uiTestStoreURL == nil)
    }

    @Test("Unit-Tests schreiben Begleitdateien nicht in den echten App-Ordner")
    func unitTestsUseTemporaryRoot() throws {
        let environment = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
        let root = try #require(AppDataDirectory.root(arguments: ["FinanceTracker"], environment: environment))
        #expect(!root.path.contains("Application Support"))
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        // Der Store bleibt davon unberührt.
        #expect(AppDataDirectory.isolatedRoot(arguments: ["FinanceTracker"]) == nil)
    }

    @Test("Rauchtest: eigener isolierter Ordner, kein Bankabruf, kein Pfad außerhalb")
    func smokeTestUsesNamedIsolatedRoot() throws {
        let arguments = ["FinanceTracker", "-smoke-test", "fixture-v16"]
        let root = try #require(AppDataDirectory.isolatedRoot(arguments: arguments))
        #expect(root.lastPathComponent == "fixture-v16")
        #expect(root.deletingLastPathComponent().lastPathComponent == "FinanceTrackerSmoke")
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))

        let environment = AppLaunchEnvironment(arguments: arguments, configuration: .release)
        #expect(environment.isSmokeTestMode)
        #expect(environment.requiresIsolatedStore)
        #expect(!environment.allowsAutomaticBankSync)
        #expect(environment.uiTestStoreURL?.deletingLastPathComponent().path == root.path)

        for unsafe in ["../live", "a/b", "", ".", "name with space", String(repeating: "x", count: 65)] {
            #expect(AppDataDirectory.smokeTestName(arguments: ["FinanceTracker", "-smoke-test", unsafe]) == nil)
        }
        #expect(AppDataDirectory.smokeTestName(arguments: ["FinanceTracker", "-smoke-test"]) == nil)
    }
}
