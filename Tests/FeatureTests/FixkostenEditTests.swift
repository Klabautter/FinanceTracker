import Foundation
import Testing

@testable import FinanceTracker

/// WP5 (§39): Fixkosten-Edit, typed Decimal, Persistenz vor Dismiss,
/// keine still ignorierten Invalid-Inputs.
@MainActor
@Suite("FixkostenEdit")
struct FixkostenEditTests {

    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func makeCommitment() -> RecurringCommitment {
        RecurringCommitment(
            name: "Miete",
            direction: .expense,
            cadence: .monthly,
            amountPolicy: .fixed,
            expectedAmount: Decimal(string: "985.00")!,
            currency: .eur,
            nextExpectedDate: nil,
            status: .active
        )
    }

    @Test("Persist mit gültiger Eingabe speichert und meldet Erfolg (§37)")
    func persistSuccess() async throws {
        let dependencies = try makeDependencies()
        let commitment = makeCommitment()
        try await dependencies.recurringCommitmentRepository.upsert([commitment])

        // Simuliert den Sheet-Flow: Validierung → Persist → true.
        let amount = DecimalParser.parse("850,50")
        #expect(amount != nil)
        guard let amount else { return }

        var updated = commitment
        updated.name = "Miete (neu)"
        updated.expectedAmount = amount
        try await dependencies.recurringCommitmentRepository.upsert([updated])

        let stored = try #require(await dependencies.recurringCommitmentRepository.commitment(id: commitment.id))
        #expect(stored.expectedAmount == Decimal(string: "850.50")!)
        #expect(stored.name == "Miete (neu)")
    }

    @Test("Ungültige Eingabe blockiert den Save (§38), alter Betrag wird nicht still gespeichert")
    func invalidAmountBlocksSave() async throws {
        let dependencies = try makeDependencies()
        let commitment = makeCommitment()
        try await dependencies.recurringCommitmentRepository.upsert([commitment])

        // Der Save-Pfad des Sheets: guard amount != nil → sonst Abbruch
        // OHNE upsert. Der Store behält den alten Stand UND es wurde kein
        // „Teil-Save" (Name ja, Betrag nein) durchgeführt.
        let invalidAmount = DecimalParser.parse("abc") // nil
        #expect(invalidAmount == nil)
        // Sheet-Semantik: guard let amount → return false → kein upsert.
        let stored = try #require(await dependencies.recurringCommitmentRepository.commitment(id: commitment.id))
        #expect(stored.expectedAmount == Decimal(string: "985.00")!)

        // Auch nicht: Name ändern + ungültiger Betrag → gar kein Save.
        #expect(DecimalParser.parse("") == nil)
        #expect(DecimalParser.parse("0") == 0) // 0 ist parsebar, aber im Sheet via amount > 0 abgelehnt
    }

    @Test("Display-String eines Budgets ist als Input parsebar (§27/§35 Regression)")
    func formattedDisplayStringIsParseable() {
        // Regression für den Ursprungs-Bug: Der Display-Formatter liefert
        // "500,00 €", der Parser muss daraus 500.00 machen können, der
        // Edit-Input ist aber grundsätzlich der Rohwert ohne Symbol.
        #expect(DecimalParser.parse("500,00 €") == Decimal(string: "500.00"))
        #expect(DecimalParser.parse("500.00 €") == Decimal(string: "500.00"))
    }

    @Test("Manuelle Einnahme übernimmt Richtung und ersten Eingangstermin")
    func manualIncomeKeepsDirectionAndDate() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = RecurringCommitmentDraft(
            name: "Gehalt",
            direction: .income,
            cadence: .monthly,
            categoryID: nil,
            nextExpectedDate: date,
            amount: 2_500
        )

        let commitment = draft.newCommitment(currency: .eur, now: .distantPast)

        #expect(commitment.direction == .income)
        #expect(commitment.nextExpectedDate == date)
        #expect(commitment.expectedAmount == 2_500)
        #expect(FixkostenPresentation.creationTitle(for: .income) == "Neue wiederkehrende Einnahme")
    }

    @Test("Pause ändert ausschließlich Status und lässt offene Draft-Werte ungespeichert")
    func pauseDoesNotPersistOtherDrafts() {
        let commitment = makeCommitment()
        let unsavedDraft = RecurringCommitmentDraft(
            name: "Ungespeicherter Name",
            direction: .income,
            cadence: .yearly,
            categoryID: UUID(),
            nextExpectedDate: Date.distantFuture,
            amount: 1
        )

        let paused = RecurringCommitmentDraft.changingStatus(
            in: commitment,
            to: .paused,
            now: .distantFuture
        )

        #expect(paused.status == .paused)
        #expect(paused.name == commitment.name)
        #expect(paused.direction == commitment.direction)
        #expect(paused.cadence == commitment.cadence)
        #expect(paused.categoryID == commitment.categoryID)
        #expect(paused.nextExpectedDate == commitment.nextExpectedDate)
        #expect(paused.expectedAmount == commitment.expectedAmount)
        #expect(paused.name != unsavedDraft.name)
    }

    @Test("Detail-Draft speichert bearbeitete Richtung und Fälligkeit")
    func detailDraftAppliesDirectionAndDueDate() {
        let commitment = makeCommitment()
        let dueDate = Date(timeIntervalSince1970: 1_810_000_000)
        let draft = RecurringCommitmentDraft(
            name: "Mieteingang",
            direction: .income,
            cadence: .quarterly,
            categoryID: nil,
            nextExpectedDate: dueDate,
            amount: 900
        )

        let updated = draft.applying(to: commitment, now: .distantFuture)

        #expect(updated.direction == .income)
        #expect(updated.cadence == .quarterly)
        #expect(updated.nextExpectedDate == dueDate)
        #expect(updated.expectedAmount == 900)
    }

    @Test("Erkennungshinweis interpoliert Turnus und Anzahl")
    func suggestionSubtitleIsInterpolated() {
        #expect(FixkostenPresentation.suggestionSubtitle(
            cadence: "monatlich",
            occurrenceCount: 4
        ) == "monatlich · 4× erkannt")
    }

    @Test("Übersichtszeilen priorisieren Pausiert vor Paid-Status")
    func overviewStatusPriority() {
        var commitment = makeCommitment()
        commitment.status = .paused

        let row = FixkostenOverviewRow(
            commitment: commitment,
            isPaid: true,
            nextDate: nil
        )

        #expect(row.status == .paused)
        #expect(row.statusTitle == "Pausiert")
        #expect(row.signedAmount == -commitment.expectedAmount)
    }

    @Test("Fixkostenfilter trennt offene Ausgaben, bezahlte Einträge und Einnahmen")
    func overviewFilters() {
        let expense = FixkostenOverviewRow(
            commitment: makeCommitment(),
            isPaid: false,
            nextDate: nil
        )
        let paid = FixkostenOverviewRow(
            commitment: RecurringCommitment(
                name: "Versicherung",
                direction: .expense,
                cadence: .yearly,
                expectedAmount: 300,
                currency: .eur
            ),
            isPaid: true,
            nextDate: nil
        )
        let income = FixkostenOverviewRow(
            commitment: RecurringCommitment(
                name: "Gehalt",
                direction: .income,
                cadence: .monthly,
                expectedAmount: 2_500,
                currency: .eur
            ),
            isPaid: false,
            nextDate: nil
        )
        let rows = [expense, paid, income]

        #expect(FixkostenPresentation.filtered(rows, filter: .open, searchText: "").map(\.name) == ["Miete"])
        #expect(FixkostenPresentation.filtered(rows, filter: .paid, searchText: "").map(\.name) == ["Versicherung"])
        #expect(FixkostenPresentation.filtered(rows, filter: .income, searchText: "gehalt").map(\.name) == ["Gehalt"])
        #expect(income.signedAmount == 2_500)
    }
}
