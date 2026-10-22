import Foundation
import Testing

@testable import FinanceTracker

/// Geführte Enable-Banking-Einrichtung: Schlüsseldatei laden, Application ID
/// aus dem Dateinamen übernehmen.
@MainActor
@Suite("EnableBankingSetup")
struct EnableBankingSetupTests {
    private struct NoProviderFactory: BankProviderResolving {
        func makeBankDataProvider() -> any BankDataProvider { MockBankDataProvider() }
    }

    private func makeModel() throws -> BankConnectModel {
        let store = try SwiftDataStore(inMemory: true)
        return BankConnectModel(
            kind: .enablebanking,
            dependencies: AppDependencies.make(container: store.container, baseCurrency: .eur),
            enableBankingCredentialStore: InMemoryEnableBankingCredentialStore(applicationID: nil, privateKeyPEM: nil),
            providerFactory: NoProviderFactory()
        )
    }

    private func writeTemporaryFile(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnableBankingSetupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("Application ID wird aus dem Dateinamen des Control Panels gelesen")
    func applicationIDFromFileName() {
        let id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        #expect(BankConnectModel.applicationID(fromKeyFileName: "\(id).pem") == id)
        #expect(BankConnectModel.applicationID(fromKeyFileName: "\(id) (1).pem") == id)
        #expect(BankConnectModel.applicationID(fromKeyFileName: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.pem") == id)
        #expect(BankConnectModel.applicationID(fromKeyFileName: "private.pem") == nil)
    }

    @Test("Gültige Schlüsseldatei füllt Schlüssel und Application ID")
    func importsValidKeyFile() async throws {
        let model = try makeModel()
        let id = "12345678-9abc-def0-1234-56789abcdef0"
        let url = try writeTemporaryFile(named: "\(id).pem", contents: EnableBankingTestKeys.privatePEM)

        #expect(!model.canSaveEnableBankingCredentials)
        await model.importPrivateKeyFile(at: url)

        #expect(model.keyFileLoaded)
        #expect(model.applicationIDInput == id)
        #expect(model.privateKeyInputIsValid)
        #expect(model.canSaveEnableBankingCredentials)
    }

    @Test("Eine bereits eingetragene Application ID wird nicht überschrieben")
    func keepsTypedApplicationID() async throws {
        let model = try makeModel()
        model.applicationIDInput = "manuell-eingetragen"
        let url = try writeTemporaryFile(
            named: "12345678-9abc-def0-1234-56789abcdef0.pem",
            contents: EnableBankingTestKeys.privatePEM
        )
        await model.importPrivateKeyFile(at: url)
        #expect(model.applicationIDInput == "manuell-eingetragen")
    }

    @Test("Eine Datei ohne Schlüssel wird abgelehnt und nichts übernommen")
    func rejectsNonKeyFile() async throws {
        let model = try makeModel()
        let url = try writeTemporaryFile(named: "12345678-9abc-def0-1234-56789abcdef0.pem", contents: "kein Schlüssel")
        await model.importPrivateKeyFile(at: url)

        #expect(!model.keyFileLoaded)
        #expect(model.keyFileMessage != nil)
        #expect(model.privateKeyInput.isEmpty)
        #expect(model.applicationIDInput.isEmpty)
        #expect(!model.canSaveEnableBankingCredentials)
    }
}
