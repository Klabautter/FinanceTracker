import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@Suite("SchemaVersioning")
struct SchemaVersioningTests {
    @Test("Migrationsplan umfasst V1–V10 in korrekter Reihenfolge")
    func planCoversAllVersions() {
        #expect(FinanceTrackerSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(FinanceTrackerSchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
        #expect(FinanceTrackerSchemaV3.versionIdentifier == Schema.Version(3, 0, 0))
        #expect(FinanceTrackerSchemaV4.versionIdentifier == Schema.Version(4, 0, 0))
        #expect(FinanceTrackerSchemaV5.versionIdentifier == Schema.Version(5, 0, 0))
        #expect(FinanceTrackerSchemaV6.versionIdentifier == Schema.Version(6, 0, 0))
        #expect(FinanceTrackerSchemaV7.versionIdentifier == Schema.Version(7, 0, 0))
        // WP19: V8 = normalisierte Tag-Relation.
        #expect(FinanceTrackerSchemaV8.versionIdentifier == Schema.Version(8, 0, 0))
        // WP38: V9 = normalisierter Suchindex.
        #expect(FinanceTrackerSchemaV9.versionIdentifier == Schema.Version(9, 0, 0))
        #expect(FinanceTrackerSchemaV10.versionIdentifier == Schema.Version(10, 0, 0))
        // P2: V11 = optionale Sparziel-Spalten auf SDBudget2Entity.
        #expect(FinanceTrackerSchemaV11.versionIdentifier == Schema.Version(11, 0, 0))
        // P2: V12 = Gruppenanteile-Sidecar (Splitwise-light).
        #expect(FinanceTrackerSchemaV12.versionIdentifier == Schema.Version(12, 0, 0))
        // V13 = optionaler Anfangsbestand auf SDAccountEntity.
        #expect(FinanceTrackerSchemaV13.versionIdentifier == Schema.Version(13, 0, 0))
        #expect(FinanceTrackerMigrationPlan.schemas.count == 13)
        #expect(FinanceTrackerMigrationPlan.stages.count == 12)
    }

    @Test("V2 umfasst alle Entitäten inklusive User-Metadaten")
    func v2ContainsAllEntities() {
        let v2TypeNames = FinanceTrackerSchemaV2.models.map { String(describing: $0) }
        #expect(v2TypeNames.contains("SDTransactionAnnotationEntity"))
        #expect(v2TypeNames.contains("SDTagEntity"))
        #expect(v2TypeNames.count == 10)
    }

    @Test("V3 erweitert V2 um Split-Lines")
    func v3AddsSplitLines() {
        let v3TypeNames = FinanceTrackerSchemaV3.models.map { String(describing: $0) }
        #expect(v3TypeNames.contains("SDTransactionSplitLineEntity"))
        #expect(v3TypeNames.count == 11)

        let v1TypeNames = FinanceTrackerSchemaV1.models.map { String(describing: $0) }
        // V1 bleibt unangetastet (Roadmap #54)
        #expect(v1TypeNames.count == 8)
    }

    @Test("V1 umfasst nur den Original-Core ohne User-Metadaten")
    func v1ContainsCoreOnly() {
        let v1TypeNames = FinanceTrackerSchemaV1.models.map { String(describing: $0) }
        #expect(!v1TypeNames.contains("SDTransactionAnnotationEntity"))
        #expect(!v1TypeNames.contains("SDTagEntity"))
        #expect(v1TypeNames.count == 8)
    }

    @Test("V12 erweitert V11 um Gruppenanteile")
    func v12AddsSharedExpenseShares() {
        let v12TypeNames = FinanceTrackerSchemaV12.models.map { String(describing: $0) }
        #expect(v12TypeNames.contains("SDSharedExpenseShareEntity"))
        #expect(v12TypeNames.contains("SDBudgetGoalEntity"))
        #expect(v12TypeNames.count == 22)

        let v11TypeNames = FinanceTrackerSchemaV11.models.map { String(describing: $0) }
        #expect(!v11TypeNames.contains("SDSharedExpenseShareEntity"))
        #expect(v11TypeNames.count == 21)
    }

    @Test("V1-Store öffnet über den Migrationsplan und bleibt nutzbar")
    func v1OpensWithMigrationPlan() throws {
        let store = try SwiftDataStore(inMemory: true)
        let context = ModelContext(store.container)

        context.insert(SDAccountEntity(
            id: UUID(), connectionID: nil, institutionID: nil, name: "T",
            typeRaw: AccountType.checking.rawValue, currencyRaw: "EUR",
            maskedIdentifier: nil, ibanLast4: nil, providerAccountID: nil,
            sourceRaw: AccountSource.demo.rawValue, isActive: true
        ))
        try context.save()

        let rows = try context.fetch(FetchDescriptor<SDAccountEntity>())
        #expect(rows.count == 1)
    }

    @Test("Migration: V1-Store mit Daten wird zu V2 migriert und bewahrt alle Finanzdaten")
    func migrationPreservesFinanceData() throws {
        let v1AccountID = UUID()
        let v1CategoryID = UUID()

        // 1. Alten Store im V1-Schema erzeugen und mit Daten füllen
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("migration-test.store")

        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let configuration = ModelConfiguration(url: storeURL)
            let oldContainer = try ModelContainer(
                for: Schema(FinanceTrackerSchemaV1.models),
                configurations: [configuration]
            )
            let oldContext = ModelContext(oldContainer)

            oldContext.insert(SDAccountEntity(
                id: v1AccountID, connectionID: nil, institutionID: nil, name: "Girokonto Alt",
                typeRaw: AccountType.checking.rawValue, currencyRaw: "EUR",
                maskedIdentifier: nil, ibanLast4: nil, providerAccountID: nil,
                sourceRaw: AccountSource.demo.rawValue, isActive: true
            ))
            oldContext.insert(SDCategoryEntity(
                id: v1CategoryID, name: "Lebensmittel",
                systemIconName: "cart", colorTokenRaw: nil, parentID: nil
            ))
            try oldContext.save()
        }

        // 2. Store mit vollem Migrationsplan öffnen (V1 → V2)
        let migratedStore = try SwiftDataStore(url: storeURL)
        let context = ModelContext(migratedStore.container)

        let accounts = try context.fetch(FetchDescriptor<SDAccountEntity>())
        #expect(accounts.count == 1)
        #expect(accounts.first?.id == v1AccountID)
        #expect(accounts.first?.name == "Girokonto Alt")

        let categories = try context.fetch(FetchDescriptor<SDCategoryEntity>())
        #expect(categories.count == 1)
        #expect(categories.first?.id == v1CategoryID)

        // 3. Neue V2-Entität ist nach der Migration schreibbar
        context.insert(SDTransactionAnnotationEntity(
            id: UUID(),
            transactionID: UUID(),
            note: "Migration-Test",
            reviewed: true,
            excludedFromAnalytics: false,
            manualKindOverrideRaw: nil,
            tagIDsJSON: nil,
            createdAt: Date(),
            updatedAt: Date()
        ))
        try context.save()

        let annotations = try context.fetch(FetchDescriptor<SDTransactionAnnotationEntity>())
        #expect(annotations.count == 1)
        #expect(annotations.first?.note == "Migration-Test")
    }
}
