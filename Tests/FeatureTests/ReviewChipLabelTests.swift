import Foundation
import Testing

@testable import FinanceTracker

/// MacUX-Audit Runde 2: Der Review-Chip benennt den konkreten dominierenden
/// Grund statt vager „Einträge warten auf Prüfung".
@Suite("ReviewChipLabel")
@MainActor
struct ReviewChipLabelTests {
    @Test("Dominanter Grund wird konkret benannt, weitere Prüfungen werden mitgezählt (Priorität: Kategorie → Transfer → Händler → Währung)")
    func dominantReasonLabels() {
        #expect(DashboardView.reviewQueueLabel(for: ReviewSummary(
            uncategorizedCount: 3, unknownMerchantCount: 1, transferCandidateCount: 2, foreignCurrencyCount: 0
        )) == "3 Transaktionen ohne Kategorie · +3 weitere")

        #expect(DashboardView.reviewQueueLabel(for: ReviewSummary(
            uncategorizedCount: 0, unknownMerchantCount: 1, transferCandidateCount: 2, foreignCurrencyCount: 0
        )) == "2 mögliche Transfers · +1 weitere")

        #expect(DashboardView.reviewQueueLabel(for: ReviewSummary(
            uncategorizedCount: 0, unknownMerchantCount: 4, transferCandidateCount: 0, foreignCurrencyCount: 1
        )) == "4 unbekannte Händler · +1 weitere")

        #expect(DashboardView.reviewQueueLabel(for: ReviewSummary(
            uncategorizedCount: 0, unknownMerchantCount: 0, transferCandidateCount: 0, foreignCurrencyCount: 1
        )) == "1 Fremdwährungs-Buchung")
    }

    @Test("Singular- und Leer-Formen")
    func singularAndEmpty() {
        #expect(DashboardView.reviewQueueLabel(for: ReviewSummary(
            uncategorizedCount: 1, unknownMerchantCount: 0, transferCandidateCount: 0, foreignCurrencyCount: 0
        )) == "1 Transaktion ohne Kategorie")

        #expect(DashboardView.reviewQueueLabel(for: ReviewSummary(
            uncategorizedCount: 0, unknownMerchantCount: 0, transferCandidateCount: 0, foreignCurrencyCount: 0
        )) == "Nichts zu prüfen")
    }

    @Test("Importstatus bleibt eine kompakte Metazeile und zählt Updates mit")
    func importStatusMetaLine() {
        let batch = ImportBatch(
            providerIdentifier: "test",
            sourceRaw: "csv",
            fileName: "umsatz.csv",
            fileHashSHA256: "hash",
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 60),
            totalRows: 5,
            importedCount: 2,
            updatedCount: 1,
            duplicateCount: 1,
            failedCount: 1
        )

        let label = DashboardView.importStatusText(for: batch)
        #expect(label.contains("3 Buchungen übernommen"))
        #expect(label.hasSuffix("1 Fehler"))
    }

    @Test("Eine einzelne Aufgabe belegt keine eigene Dashboard-Spalte")
    func sideRailRequiresMultipleWorkAreas() {
        #expect(!DashboardView.shouldUseSideRail(availableWidth: 1_200, nextStepCount: 1))
        #expect(!DashboardView.shouldUseSideRail(availableWidth: 900, nextStepCount: 3))
        #expect(DashboardView.shouldUseSideRail(availableWidth: 1_200, nextStepCount: 2))
    }
}
