import Foundation
import SwiftData
import Testing

@testable import FinanceTracker

@MainActor
@Suite("Fixkosten")
struct FixkostenTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func makeCommitment(
        name: String = "Spotify",
        direction: RecurringCommitment.Direction = .expense,
        amount: Decimal = Decimal(string: "10.99")!,
        policy: RecurringCommitment.AmountPolicy = .fixed
    ) -> RecurringCommitment {
        RecurringCommitment(
            name: name,
            merchantKey: CategoryRuleEngine.normalizedKey(name),
            direction: direction,
            cadence: .monthly,
            amountPolicy: policy,
            expectedAmount: amount,
            currency: .eur
        )
    }

    private func txn(
        merchant: String,
        amount: Decimal,
        dayOffset: Int = 0
    ) -> Transaction {
        let calendar = Calendar(identifier: .gregorian)
        return Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .demo,
            externalID: UUID().uuidString,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: calendar.date(byAdding: .day, value: dayOffset, to: Date()),
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
    }

    @Test("Paid-Matching: Merchant-Signatur + Richtung + Fix-Betragstoleranz")
    func paidMatching() {
        let commitment = makeCommitment(name: "Spotify", amount: Decimal(string: "10.99")!)

        // Passend
        let match = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "10.99")!)
        #expect(!RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [match]).isEmpty)

        // Falscher Betrag (fix, über Toleranz)
        let wrongAmount = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "49.99")!)
        #expect(RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [wrongAmount]).isEmpty)

        // Falsche Richtung (Einnahme)
        var income = txn(merchant: "SPOTIFY AB", amount: Decimal(string: "10.99")!)
        income.kind = .income
        #expect(RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [income]).isEmpty)

        // Rückerstattungen, ausgeschlossene Buchungen und manuelle Transfers
        // dürfen nicht als bezahlte Fixkosten gelten.
        var refund = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "10.99")!)
        refund.kind = .refund
        #expect(RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [refund]).isEmpty)

        var excluded = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "10.99")!)
        excluded.excludedFromAnalytics = true
        #expect(RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [excluded]).isEmpty)

        let manualTransfer = EffectiveTransactionResolver().applying(
            annotation: TransactionAnnotation(
                transactionID: match.id,
                manualKindOverride: .transfer
            ),
            to: match
        )
        #expect(RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [manualTransfer]).isEmpty)

        // Fremder Merchant
        let other = txn(merchant: "NETFLIX", amount: -Decimal(string: "10.99")!)
        #expect(RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [other]).isEmpty)
    }

    @Test("Paid-Matching greift auch über Bank-Rohtext, wenn der Anzeigename bereinigt ist")
    func paidMatchingUsesRawBankFields() {
        var commitment = makeCommitment(name: "Miete", amount: Decimal(string: "985.00")!)
        commitment.merchantKey = "MIETE MUSTERSTRASSE"
        let calendar = Calendar(identifier: .gregorian)
        let rent = Transaction(
            id: UUID(),
            accountID: UUID(),
            source: .demo,
            externalID: UUID().uuidString,
            status: .booked,
            kind: .purchase,
            amount: Money(amount: -Decimal(string: "985.00")!, currency: .eur),
            bookedAt: calendar.date(byAdding: .day, value: -3, to: Date()),
            rawDescription: "MIETE MUSTERSTRASSE 12",
            rawMerchantName: "MIETE MUSTERSTRASSE 12",
            merchantDisplayName: "Vermieter Musterstraße"
        )
        #expect(RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [rent]).map(\.id) == [rent.id])

        // Betragstoleranz gilt weiterhin auch beim Rohtext-Treffer.
        var wrongAmount = rent
        wrongAmount.amount = Money(amount: -Decimal(string: "120.00")!, currency: .eur)
        #expect(RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [wrongAmount]).isEmpty)
    }

    @Test("Fluctuating-Policy matcht ohne Betragskriterium (z. B. Strom)")
    func fluctuatingMatching() {
        let commitment = makeCommitment(
            name: "Stadtwerke",
            amount: Decimal(string: "80.00")!,
            policy: .fluctuating
        )
        let match = txn(merchant: "STADTWERKE MONATSABRECHNUNG", amount: -Decimal(string: "143.87")!)
        #expect(!RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [match]).isEmpty)
    }

    @Test("Income-Commitment matcht positive Gehaltsbuchung (#117)")
    func incomeCommitment() {
        let salary = makeCommitment(name: "Acme GmbH Gehalt", direction: .income, amount: Decimal(string: "2850.00")!)
        var income = txn(merchant: "ACME GMBH GEHALT", amount: Decimal(string: "2850.00")!)
        income.kind = .income
        #expect(!RecurringPaymentMatcher.matchingTransactions(for: salary, in: [income]).isEmpty)
    }

    // MARK: - WP4: Identity = merchantKey, nicht Display-Name

    @Test("Umbenennen bricht das Matching nicht (Identity bleibt merchantKey)")
    func renameDoesNotBreakMatching() {
        var commitment = makeCommitment(name: "Spotify", amount: Decimal(string: "10.99")!)
        let match = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "10.99")!)

        #expect(!RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [match]).isEmpty)

        // Nutzer benennt das Abo um: Matching muss weiter funktionieren.
        commitment.name = "Musik-Abo"
        #expect(!RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [match]).isEmpty)
    }

    @Test("Merchant-Varianten matchen über den normalisierten Key")
    func merchantVariantNormalization() {
        let commitment = makeCommitment(name: "Spotify", amount: Decimal(string: "10.99")!)
        let variants = [
            txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "10.99")!),
            txn(merchant: "Spotify Stockholm", amount: -Decimal(string: "10.99")!),
            txn(merchant: "spotify premium", amount: -Decimal(string: "10.99")!)
        ]
        for variant in variants {
            #expect(!RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [variant]).isEmpty)
        }
    }

    @Test("Fremder Merchant matcht nicht")
    func differentMerchantNoMatch() {
        let commitment = makeCommitment(name: "Spotify", amount: Decimal(string: "10.99")!)
        let other = txn(merchant: "DEEZER", amount: -Decimal(string: "10.99")!)
        #expect(RecurringPaymentMatcher.matchingTransactions(for: commitment, in: [other]).isEmpty)
    }

    @Test("Manuelles Commitment ohne merchantKey wird nicht heuristisch gematcht")
    func manualWithoutKeyNoHeuristic() {
        // Name "Netflix" allein ist KEINE stabile Identity mehr: Ein
        // zufällig gleich heißer Merchant matcht nicht ohne merchantKey.
        let manual = RecurringCommitment(
            name: "Netflix",
            merchantKey: nil,
            direction: .expense,
            cadence: .monthly,
            amountPolicy: .fixed,
            expectedAmount: Decimal(string: "13.99")!,
            currency: .eur
        )
        let txn = txn(merchant: "NETFLIX", amount: -Decimal(string: "13.99")!)
        #expect(RecurringPaymentMatcher.matchingTransactions(for: manual, in: [txn]).isEmpty)
    }

    @Test("Leerer/Whitespace-merchantKey wird nicht als Identity genutzt")
    func emptyKeyNoMatch() {
        let manual = RecurringCommitment(
            name: "Netflix",
            merchantKey: "   ",
            direction: .expense,
            cadence: .monthly,
            amountPolicy: .fixed,
            expectedAmount: Decimal(string: "13.99")!,
            currency: .eur
        )
        let txn = txn(merchant: "NETFLIX", amount: -Decimal(string: "13.99")!)
        #expect(RecurringPaymentMatcher.matchingTransactions(for: manual, in: [txn]).isEmpty)
    }

    @Test("Persistenz: Commitment + Occurrences, Delete entfernt Occurrences")
    func persistenceRoundtrip() async throws {
        let dependencies = try makeDependencies()
        let commitment = makeCommitment()
        try await dependencies.recurringCommitmentRepository.upsert([commitment])

        let loaded = try await dependencies.recurringCommitmentRepository.commitments()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Spotify")

        let txn = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "10.99")!)
        try await dependencies.transactionRepository.upsert([txn])
        try await dependencies.recurringCommitmentRepository.addOccurrence(
            RecurringOccurrence(commitmentID: commitment.id, transactionID: txn.id)
        )
        let occurrences = try await dependencies.recurringCommitmentRepository.occurrences(commitmentID: commitment.id)
        #expect(occurrences.count == 1)

        try await dependencies.recurringCommitmentRepository.delete(id: commitment.id)
        #expect(try await dependencies.recurringCommitmentRepository.commitments().isEmpty)
        #expect(try await dependencies.recurringCommitmentRepository.occurrences(commitmentID: commitment.id).isEmpty)
        #expect(try await dependencies.transactionRepository.count() == 1) // Transaktion bleibt
    }

    @Test("Historie berücksichtigt Ausschluss, Refund und manuelle Transfer-Korrektur")
    func historyUsesEffectiveTransactionSemantics() async throws {
        let dependencies = try makeDependencies()
        let commitment = makeCommitment()
        try await dependencies.recurringCommitmentRepository.upsert([commitment])

        let calendar = Calendar.current
        let now = Date()
        let currentComponents = calendar.dateComponents([.year, .month], from: now)
        let monthStart = calendar.date(from: currentComponents)!
        let day = min(calendar.component(.day, from: now), 20)
        var excludedPurchase = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "10.99")!)
        excludedPurchase.bookedAt = calendar.date(byAdding: .day, value: day - 1, to: monthStart)
        var manualTransfer = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "10.99")!)
        manualTransfer.bookedAt = calendar.date(byAdding: .month, value: -1, to: monthStart)
        manualTransfer.bookedAt = calendar.date(byAdding: .day, value: day - 1, to: manualTransfer.bookedAt!)
        var refund = txn(merchant: "SPOTIFY AB", amount: -Decimal(string: "10.99")!)
        refund.kind = .refund
        refund.bookedAt = calendar.date(byAdding: .month, value: -2, to: monthStart)
        refund.bookedAt = calendar.date(byAdding: .day, value: day - 1, to: refund.bookedAt!)

        try await dependencies.transactionRepository.upsert([excludedPurchase, manualTransfer, refund])
        try await dependencies.transactionAnnotationRepository.upsert([
            TransactionAnnotation(transactionID: excludedPurchase.id, excludedFromAnalytics: true),
            TransactionAnnotation(transactionID: manualTransfer.id, manualKindOverride: .transfer)
        ])

        let model = FixkostenModel(dependencies: dependencies)
        await model.load()

        #expect(model.errorMessage == nil)
        #expect(model.paidTransactionCounts[commitment.id] == 0)
        #expect(model.suggestions.isEmpty)
    }

    @Test("Ausgeblendeter Vorschlag lässt sich zurückholen und per Widerrufen wiederherstellen")
    func dismissedSuggestionCanBeRestored() async throws {
        let defaultsKey = "dismissedRecurringKeys"
        let previous = UserDefaults.standard.object(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer { UserDefaults.standard.set(previous, forKey: defaultsKey) }

        let dependencies = try makeDependencies()
        let accountID = UUID()
        let history = [-90, -60, -30, -1].map { offset in
            var transaction = txn(merchant: "NETFLIX", amount: -Decimal(string: "13.99")!, dayOffset: offset)
            transaction.accountID = accountID
            return transaction
        }
        try await dependencies.transactionRepository.upsert(history)

        let model = FixkostenModel(dependencies: dependencies)
        await model.load()
        let series = try #require(model.suggestions.first)

        await model.dismissSuggestion(series)
        #expect(model.suggestions.isEmpty)
        #expect(model.hiddenSuggestions.map(\.id) == [series.id])
        #expect(model.lastDismissedSuggestion?.id == series.id)

        await model.undoLastDismiss()
        #expect(model.suggestions.map(\.id) == [series.id])
        #expect(model.hiddenSuggestions.isEmpty)
        #expect(model.lastDismissedSuggestion == nil)

        await model.dismissSuggestion(series)
        await model.restoreSuggestion(series)
        #expect(model.suggestions.map(\.id) == [series.id])
    }

    @Test("Nächster Termin wird fortgeschrieben und stimmt mit der Vorschau überein")
    func nextDateAdvancesPastStoredAnchor() async throws {
        let dependencies = try makeDependencies()
        let calendar = Calendar.current
        let now = Date()
        var monthly = makeCommitment()
        monthly.nextExpectedDate = calendar.date(byAdding: .month, value: -2, to: now)
        var yearly = makeCommitment(name: "Versicherung")
        yearly.cadence = .yearly
        yearly.nextExpectedDate = calendar.date(byAdding: .month, value: -8, to: now)
        let unplanned = makeCommitment(name: "Ohne Termin")
        try await dependencies.recurringCommitmentRepository.upsert([monthly, yearly, unplanned])

        let model = FixkostenModel(dependencies: dependencies)
        await model.load()

        #expect(model.errorMessage == nil)
        let nextMonthly = try #require(model.nextExpectedDates[monthly.id])
        let nextYearly = try #require(model.nextExpectedDates[yearly.id])
        #expect(nextMonthly >= now)
        #expect(nextYearly >= now)
        #expect(calendar.component(.day, from: nextYearly) == calendar.component(.day, from: yearly.nextExpectedDate!))
        for entry in model.upcomingWithin30Days where entry.commitment.id == monthly.id {
            #expect(entry.scheduledDate == nextMonthly)
        }
        #expect(model.nextExpectedDates[unplanned.id] == nil)
        #expect(!model.upcomingWithin30Days.contains { $0.commitment.id == unplanned.id })
    }

    @Test("V4-Store wird zu V5 migriert (Recurring-Tabellen entstehen)")
    func migrationV4ToV5() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recurring-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("migration.store")
        defer { try? FileManager.default.removeItem(at: directory) }

        // V4-Store erzeugen (mit einer Zeile, wie im bewährten V2→V3-Muster)
        do {
            let configuration = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(
                for: Schema(versionedSchema: FinanceTrackerSchemaV4.self),
                configurations: [configuration]
            )
            let context = ModelContext(container)
            context.insert(SDBudget2Entity(
                id: UUID(),
                name: "Legacy Budget",
                systemIconName: "chart.pie",
                amountValue: "50",
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

        // V5 öffnen
        let migrated = try SwiftDataStore(url: storeURL)
        let context = ModelContext(migrated.container)

        context.insert(SDRecurringCommitmentEntity(
            id: UUID(),
            name: "Netflix",
            merchantKey: "NETFLIX",
            directionRaw: "expense",
            cadenceRaw: "monthly",
            amountPolicyRaw: "fixed",
            expectedAmountValue: "13.99",
            currencyRaw: "EUR",
            categoryID: nil,
            nextExpectedDate: nil,
            statusRaw: "active",
            originRaw: "manual",
            createdAt: Date(),
            updatedAt: Date()
        ))
        try context.save()

        let rows = try context.fetch(FetchDescriptor<SDRecurringCommitmentEntity>())
        #expect(rows.count == 1)
        #expect(rows.first?.name == "Netflix")
    }
}

@MainActor
@Suite("FixkostenLifecycle")
struct FixkostenLifecycleTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private func makeCommitment(
        name: String = "Netflix",
        direction: RecurringCommitment.Direction = .expense,
        amount: Decimal = Decimal(string: "13.99")!
    ) -> RecurringCommitment {
        RecurringCommitment(
            name: name,
            merchantKey: CategoryRuleEngine.normalizedKey(name),
            direction: direction,
            cadence: .monthly,
            amountPolicy: .fixed,
            expectedAmount: amount,
            currency: .eur
        )
    }

    @Test("Update: Name/Betrag/Kategorie ändern; Pause setzt Status")
    func updateAndPause() async throws {
        let dependencies = try makeDependencies()
        var commitment = makeCommitment(name: "Netflix")
        try await dependencies.recurringCommitmentRepository.upsert([commitment])

        commitment.name = "Netflix Premium"
        commitment.expectedAmount = Decimal(string: "17.99")!
        commitment.categoryID = UUID()
        try await dependencies.recurringCommitmentRepository.upsert([commitment])

        var loaded = try await dependencies.recurringCommitmentRepository.commitments().first
        #expect(loaded?.name == "Netflix Premium")
        #expect(loaded?.expectedAmount == Decimal(string: "17.99")!)

        commitment.status = .paused
        try await dependencies.recurringCommitmentRepository.upsert([commitment])
        loaded = try await dependencies.recurringCommitmentRepository.commitments().first
        #expect(loaded?.status == .paused)
    }
}
