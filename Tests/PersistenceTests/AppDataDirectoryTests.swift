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

    @Test("Rauchtest: Testordner wird frisch angelegt, der Fixture-Store kommt über die Standardeingabe")
    func smokeStoreIsPreparedFromStandardInput() throws {
        let name = "unit-\(UUID().uuidString.prefix(8))"
        let arguments = ["FinanceTracker", "-smoke-test", name, AppSmokeTest.fixtureFromStandardInputArgument]
        let root = try #require(AppDataDirectory.isolatedRoot(arguments: arguments))
        defer { try? FileManager.default.removeItem(at: root) }

        // Rest eines früheren Laufs, der verschwinden muss.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let leftover = root.appendingPathComponent("smoke-result.txt")
        try Data("alt".utf8).write(to: leftover)

        let pipe = Pipe()
        let fixture = Data("SQLite format 3 fixture".utf8)
        pipe.fileHandleForWriting.write(fixture)
        try pipe.fileHandleForWriting.close()
        try AppSmokeTest.prepareIsolatedStore(arguments: arguments, standardInput: pipe.fileHandleForReading)

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(try Data(contentsOf: root.appendingPathComponent("FinanceTracker.store")) == fixture)

        // Ohne das Argument: leerer Ordner, die Standardeingabe wird nicht gelesen.
        try AppSmokeTest.prepareIsolatedStore(arguments: ["FinanceTracker", "-smoke-test", name])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        // Eine leere Standardeingabe ist kein leerer Store.
        let empty = Pipe()
        try empty.fileHandleForWriting.close()
        #expect(throws: AppSmokeTest.PreparationError.self) {
            try AppSmokeTest.prepareIsolatedStore(arguments: arguments, standardInput: empty.fileHandleForReading)
        }

        // Außerhalb des Rauchtests passiert nichts.
        try AppSmokeTest.prepareIsolatedStore(arguments: ["FinanceTracker"])
    }
}
