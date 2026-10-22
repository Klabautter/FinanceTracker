import Foundation
@preconcurrency import SwiftData

enum FinanceTrackerSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    /// Original-Core: Keine User-Metadaten (Annotations/Tags).
    /// V1 nicht mehr in-place verändern: neue persistente Features gehören in V2+.
    static var models: [any PersistentModel.Type] {
        [
            SDAccountEntity.self,
            SDCategoryEntity.self,
            SDMerchantEntity.self,
            SDTransactionEntity.self,
            SDRuleEntity.self,
            SDImportBatchEntity.self,
            SDConnectionEntity.self,
            SDBudgetEntity.self
        ]
    }
}

enum FinanceTrackerSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SDAccountEntity.self,
            SDCategoryEntity.self,
            SDMerchantEntity.self,
            SDTransactionEntity.self,
            SDRuleEntity.self,
            SDImportBatchEntity.self,
            SDConnectionEntity.self,
            SDTransactionAnnotationEntity.self,
            SDTagEntity.self,
            SDBudgetEntity.self
        ]
    }
}

/// V3: + TransactionSplitLines (Roadmap #68). Neue Tabelle, V2-Stores
/// migrieren lightweight. Die V2-Entity-Klassen bleiben unverändert,
/// damit bestehende V2-Stores sauber erkannt werden.
enum FinanceTrackerSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SDAccountEntity.self,
            SDCategoryEntity.self,
            SDMerchantEntity.self,
            SDTransactionEntity.self,
            SDRuleEntity.self,
            SDImportBatchEntity.self,
            SDConnectionEntity.self,
            SDTransactionAnnotationEntity.self,
            SDTagEntity.self,
            SDBudgetEntity.self,
            SDTransactionSplitLineEntity.self
        ]
    }
}

/// V4: Budget 2.0 (Roadmap #96–99). Die Legacy-Budget-Tabelle bleibt im
/// Schema erhalten (read-only für den Auto-Convert beim ersten Laden).
enum FinanceTrackerSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SDAccountEntity.self,
            SDCategoryEntity.self,
            SDMerchantEntity.self,
            SDTransactionEntity.self,
            SDRuleEntity.self,
            SDImportBatchEntity.self,
            SDConnectionEntity.self,
            SDTransactionAnnotationEntity.self,
            SDTagEntity.self,
            SDBudgetEntity.self,
            SDBudget2Entity.self,
            SDTransactionSplitLineEntity.self
        ]
    }
}

/// V5: Fixkosten & Abos (Roadmap #105–119), zwei neue Tabellen,
/// bestehende Entitäten unverändert → lightweight.
enum FinanceTrackerSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SDAccountEntity.self,
            SDCategoryEntity.self,
            SDMerchantEntity.self,
            SDTransactionEntity.self,
            SDRuleEntity.self,
            SDImportBatchEntity.self,
            SDConnectionEntity.self,
            SDTransactionAnnotationEntity.self,
            SDTagEntity.self,
            SDBudgetEntity.self,
            SDBudget2Entity.self,
            SDTransactionSplitLineEntity.self,
            SDRecurringCommitmentEntity.self,
            SDRecurringOccurrenceEntity.self
        ]
    }
}

/// Migrationskette V1→V5: ausschließlich Lightweight-Stages.
///
/// Bewusst KEINE Custom-Stages: Der SwiftData-Staged-Migration-Manager
/// bricht die Kette, wenn auf eine Custom-Stage weitere Versionen folgen
/// („loadIssueModelContainer“). Datenübernahmen (z. B. Legacy-Budgets →
/// Budget 2.0) laufen stattdessen idempotent beim ersten Laden
/// (BudgetsModel/Repository: „Auto-Convert on read“, Roadmap Milestone F).
/// V6: Budget-History (Roadmap #99), eine neue Tabelle, additive Änderung.
enum FinanceTrackerSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SDAccountEntity.self,
            SDCategoryEntity.self,
            SDMerchantEntity.self,
            SDTransactionEntity.self,
            SDRuleEntity.self,
            SDImportBatchEntity.self,
            SDConnectionEntity.self,
            SDTransactionAnnotationEntity.self,
            SDTagEntity.self,
            SDBudgetEntity.self,
            SDBudget2Entity.self,
            SDTransactionSplitLineEntity.self,
            SDRecurringCommitmentEntity.self,
            SDRecurringOccurrenceEntity.self,
            SDBudgetAmountHistoryEntity.self
        ]
    }
}

/// V7: Attachments/Receipts (Roadmap #143–148), eine neue Tabelle,
/// additive Änderung. Dateiinhalte liegen im Dateisystem (#145).
enum FinanceTrackerSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SDAccountEntity.self,
            SDCategoryEntity.self,
            SDMerchantEntity.self,
            SDTransactionEntity.self,
            SDRuleEntity.self,
            SDImportBatchEntity.self,
            SDConnectionEntity.self,
            SDTransactionAnnotationEntity.self,
            SDTagEntity.self,
            SDBudgetEntity.self,
            SDBudget2Entity.self,
            SDTransactionSplitLineEntity.self,
            SDRecurringCommitmentEntity.self,
            SDRecurringOccurrenceEntity.self,
            SDBudgetAmountHistoryEntity.self,
            SDTransactionAttachmentEntity.self
        ]
    }
}

/// V8: Normalisierte Tag-Relation (WP19), eine neue Tabelle, additive
/// Änderung → lightweight. Bestehende tagIDsJSON-Bestände werden idempotent
/// in Join-Rows zurückgefüllt (Backfill on first use, PersistenceModelActor).
enum FinanceTrackerSchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SDAccountEntity.self,
            SDCategoryEntity.self,
            SDMerchantEntity.self,
            SDTransactionEntity.self,
            SDRuleEntity.self,
            SDImportBatchEntity.self,
            SDConnectionEntity.self,
            SDTransactionAnnotationEntity.self,
            SDTagEntity.self,
            SDBudgetEntity.self,
            SDBudget2Entity.self,
            SDTransactionSplitLineEntity.self,
            SDRecurringCommitmentEntity.self,
            SDRecurringOccurrenceEntity.self,
            SDBudgetAmountHistoryEntity.self,
            SDTransactionAttachmentEntity.self,
            SDTransactionTagEntity.self
        ]
    }
}

/// V9: Normalisierter Suchindex (WP38), eine neue Tabelle, additive
/// Änderung → lightweight. Nicht-optionaler gefoldeter Text macht
/// `#Predicate.contains` SQL-generierbar (Such-Pushdown).
enum FinanceTrackerSchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SDAccountEntity.self,
            SDCategoryEntity.self,
            SDMerchantEntity.self,
            SDTransactionEntity.self,
            SDRuleEntity.self,
            SDImportBatchEntity.self,
            SDConnectionEntity.self,
            SDTransactionAnnotationEntity.self,
            SDTagEntity.self,
            SDBudgetEntity.self,
            SDBudget2Entity.self,
            SDTransactionSplitLineEntity.self,
            SDRecurringCommitmentEntity.self,
            SDRecurringOccurrenceEntity.self,
            SDBudgetAmountHistoryEntity.self,
            SDTransactionAttachmentEntity.self,
            SDTransactionTagEntity.self,
            SDTransactionSearchEntity.self
        ]
    }
}

/// V10: Transaction Collections (Produktname später „Pocket") und ihre
/// expliziten Include-/Exclude-Overrides. Beide Tabellen sind additiv.
enum FinanceTrackerSchemaV10: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SDAccountEntity.self,
            SDCategoryEntity.self,
            SDMerchantEntity.self,
            SDTransactionEntity.self,
            SDRuleEntity.self,
            SDImportBatchEntity.self,
            SDConnectionEntity.self,
            SDTransactionAnnotationEntity.self,
            SDTagEntity.self,
            SDBudgetEntity.self,
            SDBudget2Entity.self,
            SDTransactionSplitLineEntity.self,
            SDRecurringCommitmentEntity.self,
            SDRecurringOccurrenceEntity.self,
            SDBudgetAmountHistoryEntity.self,
            SDTransactionAttachmentEntity.self,
            SDTransactionTagEntity.self,
            SDTransactionSearchEntity.self,
            SDTransactionCollectionEntity.self,
            SDTransactionCollectionOverrideEntity.self
        ]
    }
}

/// V11: P2 Sparziele, neue 1:1-Sidecar-Tabelle `SDBudgetGoalEntity`
/// (budgetID → Zielbetrag/-datum, nur für Budgets mit Ziel). Rein additiv →
/// lightweight. Bestehende Entity-Klassen bleiben unangetastet, damit V1–V10
/// hash-stabil bleiben (keine Duplicate-Checksums).
enum FinanceTrackerSchemaV11: VersionedSchema {
    static let versionIdentifier = Schema.Version(11, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SDAccountEntity.self,
            SDCategoryEntity.self,
            SDMerchantEntity.self,
            SDTransactionEntity.self,
            SDRuleEntity.self,
            SDImportBatchEntity.self,
            SDConnectionEntity.self,
            SDTransactionAnnotationEntity.self,
            SDTagEntity.self,
            SDBudgetEntity.self,
            SDBudget2Entity.self,
            SDTransactionSplitLineEntity.self,
            SDRecurringCommitmentEntity.self,
            SDRecurringOccurrenceEntity.self,
            SDBudgetAmountHistoryEntity.self,
            SDTransactionAttachmentEntity.self,
            SDTransactionTagEntity.self,
            SDTransactionSearchEntity.self,
            SDTransactionCollectionEntity.self,
            SDTransactionCollectionOverrideEntity.self,
            SDBudgetGoalEntity.self
        ]
    }
}

/// V12: P2 Gruppenausgaben (Splitwise-light), neue Sidecar-Tabelle
/// `SDSharedExpenseShareEntity` (N:1 zu Transaktionen, User-Metadaten #27,
/// kein Parallelmodell #11). Rein additiv → lightweight. Bestehende
/// Entity-Klassen bleiben unangetastet, damit V1–V11 hash-stabil bleiben.
enum FinanceTrackerSchemaV12: VersionedSchema {
    static let versionIdentifier = Schema.Version(12, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SDAccountEntity.self,
            SDCategoryEntity.self,
            SDMerchantEntity.self,
            SDTransactionEntity.self,
            SDRuleEntity.self,
            SDImportBatchEntity.self,
            SDConnectionEntity.self,
            SDTransactionAnnotationEntity.self,
            SDTagEntity.self,
            SDBudgetEntity.self,
            SDBudget2Entity.self,
            SDTransactionSplitLineEntity.self,
            SDRecurringCommitmentEntity.self,
            SDRecurringOccurrenceEntity.self,
            SDBudgetAmountHistoryEntity.self,
            SDTransactionAttachmentEntity.self,
            SDTransactionTagEntity.self,
            SDTransactionSearchEntity.self,
            SDTransactionCollectionEntity.self,
            SDTransactionCollectionOverrideEntity.self,
            SDBudgetGoalEntity.self,
            SDSharedExpenseShareEntity.self
        ]
    }
}

/// V13: Anfangsbestand pro Konto, neue 1:1-Sidecar-Tabelle
/// `SDAccountOpeningBalanceEntity` (accountID → Betrag/Stichtag), damit
/// Bargeld und Konten ohne Anbindung einen echten Kontostand bekommen.
/// Rein additiv → lightweight. Bestehende Entity-Klassen bleiben
/// unangetastet, damit V1–V12 hash-stabil bleiben (keine Duplicate-Checksums).
enum FinanceTrackerSchemaV13: VersionedSchema {
    static let versionIdentifier = Schema.Version(13, 0, 0)

    static var models: [any PersistentModel.Type] {
        FinanceTrackerSchemaV12.models + [SDAccountOpeningBalanceEntity.self]
    }
}

enum FinanceTrackerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            FinanceTrackerSchemaV1.self,
            FinanceTrackerSchemaV2.self,
            FinanceTrackerSchemaV3.self,
            FinanceTrackerSchemaV4.self,
            FinanceTrackerSchemaV5.self,
            FinanceTrackerSchemaV6.self,
            FinanceTrackerSchemaV7.self,
            FinanceTrackerSchemaV8.self,
            FinanceTrackerSchemaV9.self,
            FinanceTrackerSchemaV10.self,
            FinanceTrackerSchemaV11.self,
            FinanceTrackerSchemaV12.self,
            FinanceTrackerSchemaV13.self
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: FinanceTrackerSchemaV1.self,
                toVersion: FinanceTrackerSchemaV2.self
            ),
            .lightweight(
                fromVersion: FinanceTrackerSchemaV2.self,
                toVersion: FinanceTrackerSchemaV3.self
            ),
            .lightweight(
                fromVersion: FinanceTrackerSchemaV3.self,
                toVersion: FinanceTrackerSchemaV4.self
            ),
            .lightweight(
                fromVersion: FinanceTrackerSchemaV4.self,
                toVersion: FinanceTrackerSchemaV5.self
            ),
            .lightweight(
                fromVersion: FinanceTrackerSchemaV5.self,
                toVersion: FinanceTrackerSchemaV6.self
            ),
            .lightweight(
                fromVersion: FinanceTrackerSchemaV6.self,
                toVersion: FinanceTrackerSchemaV7.self
            ),
            .lightweight(
                fromVersion: FinanceTrackerSchemaV7.self,
                toVersion: FinanceTrackerSchemaV8.self
            ),
            .lightweight(
                fromVersion: FinanceTrackerSchemaV8.self,
                toVersion: FinanceTrackerSchemaV9.self
            ),
            .lightweight(
                fromVersion: FinanceTrackerSchemaV9.self,
                toVersion: FinanceTrackerSchemaV10.self
            ),
            .lightweight(
                fromVersion: FinanceTrackerSchemaV10.self,
                toVersion: FinanceTrackerSchemaV11.self
            ),
            .lightweight(
                fromVersion: FinanceTrackerSchemaV11.self,
                toVersion: FinanceTrackerSchemaV12.self
            ),
            .lightweight(
                fromVersion: FinanceTrackerSchemaV12.self,
                toVersion: FinanceTrackerSchemaV13.self
            )
        ]
    }
}
