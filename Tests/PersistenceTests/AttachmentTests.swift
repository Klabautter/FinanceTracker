import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@MainActor
@Suite("Attachments")
struct AttachmentsTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    @Test("AttachmentService: Datei wird kopiert, geladen, gelöscht")
    func serviceStoreLoadDelete() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let service = AttachmentService(attachmentsBaseDirectory: base)
        let txnID = UUID()
        let payload = Data("PDF-INHALT".utf8)

        let stored = try service.store(
            data: payload,
            fileName: "beleg.pdf",
            mimeType: "application/pdf",
            transactionID: txnID
        )

        #expect(stored.relativePath == "\(txnID.uuidString)/\(stored.attachmentID.uuidString).pdf")

        let loaded = try service.data(forRelativePath: stored.relativePath)
        #expect(loaded == payload)

        try service.delete(relativePath: stored.relativePath)
        #expect(!FileManager.default.fileExists(atPath: service.absoluteURL(forRelativePath: stored.relativePath).path))
    }

    @Test("Persistenz: Attachments je Transaktion laden/löschen")
    func persistencePerTransaction() async throws {
        let dependencies = try makeDependencies()

        try await dependencies.accountRepository.upsert([
            Account(name: "Giro", type: .checking, currency: .eur, source: .demo)
        ])
        let account = try #require(await dependencies.accountRepository.accounts().first)
        let txn = Transaction(
            id: UUID(),
            accountID: account.id,
            source: .manual,
            externalID: "att-1",
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(10), currency: .eur),
            bookedAt: Date(),
            rawDescription: "x",
            rawMerchantName: "X",
            merchantDisplayName: "X"
        )
        try await dependencies.transactionRepository.upsert([txn])

        let a1 = TransactionAttachment(
            transactionID: txn.id,
            fileName: "beleg.pdf",
            mimeType: "application/pdf",
            localRelativePath: "\(txn.id.uuidString)/a.pdf"
        )
        let a2 = TransactionAttachment(
            transactionID: txn.id,
            fileName: "foto.png",
            mimeType: "image/png",
            localRelativePath: "\(txn.id.uuidString)/b.png"
        )
        try await dependencies.transactionAttachmentRepository.add(a1)
        try await dependencies.transactionAttachmentRepository.add(a2)

        let loaded = try await dependencies.transactionAttachmentRepository.attachments(transactionID: txn.id)
        #expect(loaded.count == 2)

        try await dependencies.transactionAttachmentRepository.delete(id: a1.id)
        let afterDelete = try await dependencies.transactionAttachmentRepository.attachments(transactionID: txn.id)
        #expect(afterDelete.count == 1)
        #expect(afterDelete.first?.fileName == "foto.png")
    }

    @Test("V6-Store wird zu V7 migriert (Attachment-Tabelle entsteht)")
    func migrationV6ToV7() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("migration.store")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let configuration = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(
                for: Schema(versionedSchema: FinanceTrackerSchemaV6.self),
                configurations: [configuration]
            )
            let context = ModelContext(container)
            context.insert(SDBudget2Entity(
                id: UUID(),
                name: "Legacy",
                systemIconName: "chart.pie",
                amountValue: "100",
                currencyRaw: "EUR",
                periodPolicyRaw: "calendarMonth",
                startDay: 1,
                salaryIncomeID: nil,
                categoryIDsJSON: Data("[]".utf8),
                tagIDsJSON: nil,
                accountIDsJSON: nil,
                rolloverRaw: "reset",
                includeInForecast: true,
                enabled: true,
                createdAt: Date(),
                updatedAt: Date()
            ))
            try context.save()
        }

        let migrated = try SwiftDataStore(url: storeURL)
        let context = ModelContext(migrated.container)

        context.insert(SDTransactionAttachmentEntity(
            id: UUID(),
            transactionID: UUID(),
            fileName: "beleg.pdf",
            mimeType: "application/pdf",
            localRelativePath: "x/y.pdf",
            createdAt: Date()
        ))
        try context.save()

        let rows = try context.fetch(FetchDescriptor<SDTransactionAttachmentEntity>())
        #expect(rows.count == 1)
    }
}
