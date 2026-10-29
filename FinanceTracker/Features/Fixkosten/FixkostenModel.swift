import Foundation

/// Fixkosten & Abos (Roadmap #105–119): persistente Commitments +
/// Detector-Suggestions (bestätigen/ablehnen) + Paid-Status.
@MainActor
@Observable
final class FixkostenModel {
    let dependencies: AppDependencies

    private(set) var commitments: [RecurringCommitment] = []
    private(set) var suggestions: [RecurringSeries] = []
    /// Mit „Nicht anzeigen“ ausgeblendete Vorschläge, die weiterhin erkannt
    /// werden: Ein Verklicken lässt sich so jederzeit zurücknehmen.
    private(set) var hiddenSuggestions: [RecurringSeries] = []
    /// Zuletzt ausgeblendeter Vorschlag, für Bearbeiten → Widerrufen.
    private(set) var lastDismissedSuggestion: RecurringSeries?
    private var accountsByID: [UUID: Account] = [:]
    private var categoriesByID: [UUID: Category] = [:]
    /// WP7: Anzahl bezahlter Occurrences im aktuellen Zeitraum.
    private(set) var paidTransactionCounts: [UUID: Int] = [:]
    /// WP5/WP7: Wie viele Zahlungen explizit vom Nutzer zugeordnet sind.
    private(set) var explicitOccurrenceCounts: [UUID: Int] = [:]
    /// WP5: Datum der letzten gültigen Zahlung.
    private(set) var latestOccurrenceDates: [UUID: Date] = [:]
    private(set) var nextExpectedDates: [UUID: Date] = [:]
    /// Fixkosten, deren Konto gelöscht ist und die sich keinem anderen
    /// Konto eindeutig zuordnen lassen.
    private(set) var orphanedCommitmentIDs: Set<RecurringCommitment.ID> = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// WP7: Occurrence-Resolution pro Commitment (aktueller Zeitraum):
    /// Quelle für Summary und UI-Paid-Status (§59/§60).
    private(set) var currentPeriodResolutions: [UUID: RecurringOccurrenceResolution] = [:]

    /// Dismissed Suggestions (Roadmap #111/#119): konsistent mit der
    /// Analytics-Recurring-UI über AppStorage.
    @ObservationIgnored private var dismissedKeys: Set<String> = []

    var dataRevision: Int { dependencies.changeTracker.revision }

    private let dismissedDefaultsKey = "dismissedRecurringKeys"

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        dismissedKeys = Set(
            UserDefaults.standard.stringArray(forKey: dismissedDefaultsKey) ?? []
        )

        do {
            // Erst verwaiste Fixkosten (Konto gelöscht) aufs verbleibende
            // Konto umhängen, sonst fehlen ihre Zahlungen und der Händler
            // wird erneut vorgeschlagen.
            orphanedCommitmentIDs = try await RelinkOrphanedCommitments(
                commitmentRepository: dependencies.recurringCommitmentRepository,
                accountRepository: dependencies.accountRepository,
                transactionRepository: dependencies.transactionRepository
            ).run().orphanedIDs

            async let commitmentsTask = dependencies.recurringCommitmentRepository.commitments()
            async let allTransactionsTask = dependencies.transactionRepository.transactions(
                matching: last12MonthsQuery()
            )
            async let accountsTask = dependencies.accountRepository.accounts()
            async let categoriesTask = dependencies.categoryRepository.categories()
            async let occurrencesTask = dependencies.recurringCommitmentRepository.allOccurrences()

            let accounts = try await accountsTask
            accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            categoriesByID = Dictionary(uniqueKeysWithValues: try await categoriesTask.map { ($0.id, $0) })
            commitments = try await commitmentsTask
            let rawHistoryTransactions = try await allTransactionsTask
            let annotations = try await dependencies.transactionAnnotationRepository.annotations(
                transactionIDs: Set(rawHistoryTransactions.map(\.id))
            )
            let historyTransactions = EffectiveTransactionResolver().applying(
                annotations: annotations,
                to: rawHistoryTransactions
            )
            let allOccurrences = try await occurrencesTask

            // WP7: Occurrence-Level-Resolution: geplante Vorkommen werden
            // einzeln aufgelöst (explizit → heuristisch → offen).
            let resolver = RecurringOccurrenceResolver()
            let occurrencesByCommitment = Dictionary(grouping: allOccurrences, by: \.commitmentID)
            let currentPeriod = currentMonthInterval()

            paidTransactionCounts = [:]
            explicitOccurrenceCounts = [:]
            latestOccurrenceDates = [:]
            nextExpectedDates = [:]
            currentPeriodResolutions = [:]

            for commitment in commitments {
                let result = resolver.resolve(
                    commitment: commitment,
                    explicitOccurrences: occurrencesByCommitment[commitment.id] ?? [],
                    allTransactions: historyTransactions,
                    period: currentPeriod
                )
                paidTransactionCounts[commitment.id] = result.matchedTransactions.count
                explicitOccurrenceCounts[commitment.id] = result.isExplicitlyAssigned
                    ? result.matchedTransactions.count
                    : 0
                latestOccurrenceDates[commitment.id] = result.latestOccurrence

                if let latest = result.latestOccurrence {
                    nextExpectedDates[commitment.id] = RecurringScheduleService().nextDate(
                        after: latest,
                        cadence: commitment.cadence,
                        calendar: Calendar.current
                    ) ?? commitment.nextExpectedDate
                } else {
                    nextExpectedDates[commitment.id] = commitment.nextExpectedDate
                }

                // WP7: Occurrence-Resolution für die Summary (§59).
                currentPeriodResolutions[commitment.id] = resolver.resolveOccurrences(
                    commitment: commitment,
                    explicitOccurrences: occurrencesByCommitment[commitment.id] ?? [],
                    allTransactions: historyTransactions,
                    period: currentPeriod,
                    calendar: Calendar.current,
                    latestPaymentDate: latestOccurrenceDates[commitment.id]
                )
            }

            recomputeSummary()
            computeUpcoming30Days(
                historyTransactions: historyTransactions,
                occurrencesByCommitment: occurrencesByCommitment
            )

            // Suggestions: Detector über die Historie, gefiltert auf
            // noch nicht bestätigte/dismissed Merchants.
            let detector = RecurringPaymentsDetector()
            let detected = detector.detect(transactions: historyTransactions, calendar: .current)
            let confirmedKeys = Set(commitments.compactMap { commitment in
                commitment.merchantKey.map { $0 + "|" + commitment.currency.rawValue }
            })
            let open = detected.filter { series in
                !confirmedKeys.contains(RecurringMerchantIdentity(accountID: series.accountID, merchantKey: series.merchantKey).persistedKey + "|" + series.currency.rawValue)
            }
            suggestions = open.filter { !dismissedKeys.contains(dismissKey(for: $0)) }
            hiddenSuggestions = open.filter { dismissedKeys.contains(dismissKey(for: $0)) }
        } catch {
            errorMessage = String(localized: "Fixkosten konnten nicht geladen werden.")
        }
    }

    // MARK: - Commitment Actions

    func accountLabel(for series: RecurringSeries) -> String {
        guard let account = accountsByID[series.accountID] else { return String(localized: "Konto nicht verfügbar") }
        return account.name + " · " + account.presentationIdentifier
    }

    /// Kategorie eines Zahlungsplans für die Anzeige; `nil` = ohne.
    func category(for commitment: RecurringCommitment) -> Category? {
        commitment.categoryID.flatMap { categoriesByID[$0] }
    }

    func confirmSuggestion(_ series: RecurringSeries, categoryID: UUID?) async {
        let commitment = RecurringCommitment(
            name: series.displayName,
            merchantKey: RecurringMerchantIdentity(accountID: series.accountID, merchantKey: series.merchantKey).persistedKey,
            direction: .expense,
            cadence: cadence(from: series.cadence),
            amountPolicy: .fixed,
            expectedAmount: series.medianAmount,
            currency: series.currency,
            categoryID: categoryID,
            nextExpectedDate: series.nextExpectedDate,
            status: .active,
            origin: .confirmedDetection
        )
        do {
            try await dependencies.recurringCommitmentRepository.upsert([commitment])
            markDismissed(dismissKey(for: series))
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            errorMessage = String(localized: "Abo konnte nicht bestätigt werden.")
        }
    }

    func dismissSuggestion(_ series: RecurringSeries) async {
        markDismissed(dismissKey(for: series))
        lastDismissedSuggestion = series
        await load()
    }

    /// Holt einen ausgeblendeten Vorschlag zurück in die Vorschläge.
    func restoreSuggestion(_ series: RecurringSeries) async {
        dismissedKeys.remove(dismissKey(for: series))
        UserDefaults.standard.set(Array(dismissedKeys), forKey: dismissedDefaultsKey)
        if lastDismissedSuggestion?.id == series.id {
            lastDismissedSuggestion = nil
        }
        await load()
    }

    func undoLastDismiss() async {
        guard let series = lastDismissedSuggestion else { return }
        await restoreSuggestion(series)
    }

    func createManualCommitment(
        name: String,
        direction: RecurringCommitment.Direction,
        cadence: RecurringCommitment.Cadence,
        amount: Decimal,
        categoryID: UUID?
    ) async {
        let commitment = RecurringCommitment(
            name: name,
            direction: direction,
            cadence: cadence,
            amountPolicy: .fixed,
            expectedAmount: amount,
            currency: dependencies.baseCurrency,
            categoryID: categoryID,
            nextExpectedDate: nil,
            status: .active,
            origin: .manual
        )
        do {
            try await dependencies.recurringCommitmentRepository.upsert([commitment])
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            errorMessage = String(localized: "Fixkosten konnten nicht gespeichert werden.")
        }
    }

    func delete(_ commitment: RecurringCommitment) async {
        do {
            try await dependencies.recurringCommitmentRepository.delete(id: commitment.id)
            dependencies.changeTracker.markChanged()
            await load()
        } catch {
            errorMessage = String(localized: "Fixkosten konnten nicht gelöscht werden.")
        }
    }

    // MARK: - Kennzahlen (#113 / WP6)

    /// WP6: Fachlich korrekte Summary über den RecurringSummaryCalculator.
    /// Basis-Summen nur in Base Currency; Fremdwährungen separat.
    private(set) var summary = RecurringSummaryCalculator.Summary(
        expenseMonthlyEquivalent: 0,
        expenseDueInPeriod: 0,
        openDueInPeriod: 0,
        incomeMonthlyEquivalent: 0,
        incomeDueInPeriod: 0,
        foreignExpense: [],
        foreignIncome: [],
        currenciesWithoutPlan: []
    )

    /// Kompatibilitäts-Property für die UI: „Ø monatlich“ (Ausgaben,
    /// Base Currency).
    var monthlyTotal: Decimal { summary.expenseMonthlyEquivalent }

    /// „Fällig in dieser Periode“ (Ausgaben, Base Currency).
    var dueInPeriodTotal: Decimal { summary.expenseDueInPeriod }

    /// „Noch offen“ in dieser Periode (fällig und nicht bezahlt).
    var openTotal: Decimal { summary.openDueInPeriod }

    /// „Ø monatlich“ der wiederkehrenden Einnahmen (Base Currency).
    var incomeTotal: Decimal { summary.incomeMonthlyEquivalent }

    /// WP7 (§53): „Kommende Zahlungen" ist occurrence-basiert: ein
    /// wöchentliches Commitment erscheint pro geplantem Termin, nicht
    /// pauschal als ganzes Commitment.
    struct UpcomingEntry: Identifiable, Equatable {
        let commitment: RecurringCommitment
        let scheduledDate: Date
        var isOverdue = false
        var id: String { commitment.id.uuidString + "|\(scheduledDate.timeIntervalSince1970)" }
    }

    private(set) var upcomingWithin30Days: [UpcomingEntry] = []

    private func computeUpcoming30Days(
        historyTransactions: [Transaction],
        occurrencesByCommitment: [UUID: [RecurringOccurrence]]
    ) {
        let calendar = Calendar.current
        let now = Date()
        guard let windowEnd = calendar.date(byAdding: .day, value: 30, to: now),
              let planningEnd = calendar.date(byAdding: .month, value: 13, to: now) else {
            upcomingWithin30Days = []
            return
        }
        let resolver = RecurringOccurrenceResolver()

        upcomingWithin30Days = commitments
            .filter { $0.status == .active }
            .flatMap { commitment -> [UpcomingEntry] in
                guard commitment.nextExpectedDate != nil || latestOccurrenceDates[commitment.id] != nil else {
                    return []
                }
                // Der Planungshorizont deckt auch jährliche nächste Termine ab;
                // die Vorschau zeigt nur offene Vorkommen der nächsten 30 Tage.
                // Historie + explizite
                // Zuordnungen fließen ein, damit bereits bezahlte Vorkommen
                // nicht als offen erscheinen.
                let openOccurrences = resolver.openOccurrences(
                    commitment: commitment,
                    explicitOccurrences: occurrencesByCommitment[commitment.id] ?? [],
                    allTransactions: historyTransactions,
                    now: now,
                    end: planningEnd,
                    calendar: calendar,
                    latestPaymentDate: latestOccurrenceDates[commitment.id]
                )
                // „Nächster Termin" bleibt ein kommender Termin; nur wenn es
                // keinen gibt, zeigt er den überfälligen.
                let today = calendar.startOfDay(for: now)
                if let next = (openOccurrences.first { $0.scheduledDate >= today } ?? openOccurrences.first)?.scheduledDate {
                    nextExpectedDates[commitment.id] = next
                }
                return openOccurrences
                    .filter { $0.scheduledDate < windowEnd }
                    .map { occurrence in
                        UpcomingEntry(
                            commitment: commitment,
                            scheduledDate: occurrence.scheduledDate,
                            isOverdue: occurrence.isOverdue(now: now, calendar: calendar)
                        )
                    }
            }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private func recomputeSummary() {
        let calculator = RecurringSummaryCalculator()
        // WP7 (§59): Summary konsumiert die Occurrence-Resolutions statt
        // eines groben Commitment-Level-Paid-Flags.
        summary = calculator.summary(
            commitments: commitments,
            latestOccurrences: latestOccurrenceDates,
            resolutions: currentPeriodResolutions,
            period: currentMonthInterval(),
            baseCurrency: dependencies.baseCurrency,
            calendar: Calendar.current
        )
    }

    // MARK: - Helpers

    private func dismissKey(for series: RecurringSeries) -> String {
        series.id
    }

    private func markDismissed(_ key: String) {
        dismissedKeys.insert(key)
        UserDefaults.standard.set(Array(dismissedKeys), forKey: dismissedDefaultsKey)
    }

    private func cadence(from seriesCadence: RecurringSeries.Cadence) -> RecurringCommitment.Cadence {
        switch seriesCadence {
        case .weekly: .weekly
        case .monthly: .monthly
        case .quarterly: .quarterly
        case .yearly: .yearly
        }
    }

    private func currentMonthQuery() -> TransactionQuery {
        var query = TransactionQuery()
        query.dateInterval = currentMonthInterval()
        return query
    }

    private func currentMonthInterval() -> DateInterval {
        let calendar = Calendar.current
        let now = Date()
        if let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
           let end = calendar.date(byAdding: .month, value: 1, to: start) {
            return DateInterval(start: start, end: end)
        }
        return DateInterval(start: .distantPast, end: .distantFuture)
    }

    private func last12MonthsQuery() -> TransactionQuery {
        var query = TransactionQuery()
        let calendar = Calendar.current
        let now = Date()
        if let currentStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
           let start = calendar.date(byAdding: .month, value: -11, to: currentStart),
           let end = calendar.date(byAdding: .month, value: 1, to: currentStart) {
            query.dateInterval = DateInterval(start: start, end: end)
        }
        return query
    }
}
