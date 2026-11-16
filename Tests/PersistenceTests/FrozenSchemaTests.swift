import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

/// Schutz für bestehende Nutzer-Datenbanken.
///
/// 1. Die Form jeder ausgelieferten Schema-Version ist als Text eingefroren
///    (`Tests/Fixtures/stores/schema-vN.txt`). Ändert jemand eine Entity, die
///    eine alte Version noch verwendet, schlägt der Test fehl: Dann gehört die
///    Änderung in eine neue Version, und die alte bekommt eine eingefrorene
///    Kopie der Entity.
/// 2. Für jede ausgelieferte Version liegt eine echte Datenbankdatei unter
///    `Tests/Fixtures/stores/`. Sie wird mit dem aktuellen Code geöffnet und
///    migriert; die Daten müssen lesbar bleiben.
///
/// Neue Fixture erzeugen (nur beim Einführen einer neuen Version):
/// `TEST_RUNNER_FT_FIXTURE_OUT=<Ordner> xcodebuild test … -only-testing:FinanceTrackerTests_macOS/FrozenSchemaTests`
@Suite("FrozenSchema")
struct FrozenSchemaTests {
    /// Ausgelieferte Versionen mit eingefrorener Form und Datenbankdatei.
    static let shippedVersions: [(version: Int, models: [any PersistentModel.Type])] = [
        (16, FinanceTrackerSchemaV16.models),
        (17, FinanceTrackerSchemaV17.models)
    ]

    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/stores", isDirectory: true)
    }

    /// Lesbare, stabile Beschreibung eines Schemas: Entities, Attribute,
    /// Typen, Optionalität, Eindeutigkeit.
    static func shape(of models: [any PersistentModel.Type]) -> String {
        Schema(models).entities
            .sorted { $0.name < $1.name }
            .map { entity in
                let attributes = entity.attributes
                    .sorted { $0.name < $1.name }
                    .map { attribute in
                        var line = "  \(attribute.name): \(String(describing: attribute.valueType))"
                        if attribute.isOptional { line += "?" }
                        if attribute.isUnique { line += " unique" }
                        return line
                    }
                let relationships = entity.relationships
                    .sorted { $0.name < $1.name }
                    .map { "  -> \($0.name): \($0.destination)" }
                return ([entity.name] + attributes + relationships).joined(separator: "\n")
            }
            .joined(separator: "\n") + "\n"
    }

    @Test("Ausgelieferte Schema-Versionen behalten ihre Form", arguments: [16, 17])
    func shippedShapeIsFrozen(version: Int) throws {
        let models = try #require(Self.shippedVersions.first { $0.version == version }?.models)
        let expected = try String(
            contentsOf: Self.fixturesDirectory.appendingPathComponent("schema-v\(version).txt"),
            encoding: .utf8
        )
        let actual = Self.shape(of: models)
        #expect(
            actual == expected,
            "Schema V\(version) hat sich geändert. Bestehende Datenbanken ließen sich dann nicht mehr öffnen: Änderung in eine neue Version legen und V\(version) eine eingefrorene Kopie der Entity geben."
        )
    }

    @Test("Datenbank jeder ausgelieferten Version öffnet und migriert", arguments: [16, 17])
    func shippedStoreOpens(version: Int) async throws {
        let fixture = Self.fixturesDirectory.appendingPathComponent("FinanceTracker-v\(version).store")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrozenSchema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("FinanceTracker.store")
        try FileManager.default.copyItem(at: fixture, to: copy)

        let store = try SwiftDataStore(url: copy)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let accounts = try await dependencies.accountRepository.accounts()
        let transactions = try await dependencies.transactionRepository.transactions(matching: TransactionQuery())
        let budgets = try await dependencies.budgetRepository.budgets()
        let commitments = try await dependencies.recurringCommitmentRepository.commitments()
        #expect(!accounts.isEmpty)
        #expect(transactions.count > 100)
        #expect(!budgets.isEmpty)
        #expect(!commitments.isEmpty)
        // Ein Backup des migrierten Bestands muss sich wiederherstellen lassen.
        let backup = try await BackupService.makeBackup(dependencies: dependencies)
        try BackupRestoreService.validate(backup)
    }

    /// Erzeugt Form-Datei und Datenbank der aktuellen Version, wenn
    /// `FT_FIXTURE_OUT` gesetzt ist; sonst ohne Wirkung.
    @Test("Fixture der aktuellen Version erzeugen (nur auf Anforderung)")
    func generateCurrentFixture() throws {
        guard let out = ProcessInfo.processInfo.environment["FT_FIXTURE_OUT"], !out.isEmpty else { return }
        let directory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let version = FinanceTrackerMigrationPlan.schemas.count
        let models = FinanceTrackerMigrationPlan.schemas.last!.models
        try Self.shape(of: models).write(
            to: directory.appendingPathComponent("schema-v\(version).txt"),
            atomically: true,
            encoding: .utf8
        )
        let url = directory.appendingPathComponent("FinanceTracker-v\(version)-wal.store")
        try? FileManager.default.removeItem(at: url)
        do {
            let store = try SwiftDataStore(url: url)
            PreviewDependencies.seedDemoData(into: store.container)
        }
    }

    @Test("Migration V16 → V17 legt die Indizes der Buchungstabelle an")
    func v17AddsIndexes() throws {
        let fixture = Self.fixturesDirectory.appendingPathComponent("FinanceTracker-v16.store")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrozenSchema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("FinanceTracker.store")
        try FileManager.default.copyItem(at: fixture, to: copy)
        do { _ = try SwiftDataStore(url: copy) }

        let indexes = try Self.indexNames(table: "ZSDTRANSACTIONENTITY", in: copy)
        #expect(indexes.contains { $0.hasSuffix("effectiveDateValue") && !$0.contains("accountID") })
        #expect(indexes.contains { $0.hasSuffix("accountIDeffectiveDateValue") })
        #expect(indexes.contains { $0.hasSuffix("importBatchID") })
        #expect(indexes.contains { $0.hasSuffix("externalID") })
    }

    /// Indexnamen einer Tabelle über das sqlite3-Werkzeug (nur lesend).
    private static func indexNames(table: String, in url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", url.path, "select name from sqlite_master where type='index' and tbl_name='\(table)';"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.split(separator: "\n").map(String.init)
    }
}
