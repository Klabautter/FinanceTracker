import Foundation

/// Fixkosten & Abos (Roadmap #105–119): persistente, vom Nutzer
/// bestätigte wiederkehrende Zahlungen. Der Detector bleibt nur
/// Suggestion-Layer (#111).
struct RecurringCommitment: Identifiable, Hashable, Codable, Sendable {
    enum Direction: String, Codable, Sendable, CaseIterable {
        case expense
        case income

        var displayName: String {
            switch self {
            case .expense: String(localized: "Ausgabe")
            case .income: String(localized: "Einnahme")
            }
        }
    }

    enum Cadence: String, Codable, Sendable, CaseIterable {
        case weekly
        case monthly
        case quarterly
        case yearly

        var displayName: String {
            switch self {
            case .weekly: String(localized: "wöchentlich")
            case .monthly: String(localized: "monatlich")
            case .quarterly: String(localized: "quartalsweise")
            case .yearly: String(localized: "jährlich")
            }
        }

        // Scheduling läuft ausschließlich über RecurringScheduleService
        // (Calendar-Komponenten). Approximierte Tagesanzahl (7/30/91/365)
        // wurde entfernt, weil sie Monats-/Schaltjahr-Drift produziert.
    }

    enum AmountPolicy: String, Codable, Sendable, CaseIterable {
        case fixed
        case fluctuating

        var displayName: String {
            switch self {
            case .fixed: String(localized: "Fester Betrag")
            case .fluctuating: String(localized: "Schwankender Betrag")
            }
        }
    }

    enum Status: String, Codable, Sendable, CaseIterable {
        case active
        case paused

        var displayName: String {
            switch self {
            case .active: String(localized: "Aktiv")
            case .paused: String(localized: "Pausiert")
            }
        }
    }

    let id: UUID

    var name: String
    var merchantKey: String?

    /// Versioned composite identity keeps account-scoped confirmations compatible
    /// with existing stores and backups; legacy merchant keys remain unscoped.
    var matchingAccountID: UUID? { merchantIdentity?.accountID }
    var matchingMerchantKey: String? { merchantIdentity?.merchantKey }
    private var merchantIdentity: RecurringMerchantIdentity? {
        merchantKey.map(RecurringMerchantIdentity.init(persistedKey:))
    }

    var direction: Direction
    var cadence: Cadence

    var amountPolicy: AmountPolicy
    var expectedAmount: Decimal
    var currency: CurrencyCode

    var categoryID: UUID?
    var nextExpectedDate: Date?

    var status: Status
    /// Roadmap #111: Wie dieses Commitment entstanden ist.
    var origin: Origin

    var createdAt: Date
    var updatedAt: Date

    enum Origin: String, Codable, Sendable {
        case manual
        case confirmedDetection
    }

    init(
        id: UUID = UUID(),
        name: String,
        merchantKey: String? = nil,
        direction: Direction = .expense,
        cadence: Cadence = .monthly,
        amountPolicy: AmountPolicy = .fixed,
        expectedAmount: Decimal,
        currency: CurrencyCode = .eur,
        categoryID: UUID? = nil,
        nextExpectedDate: Date? = nil,
        status: Status = .active,
        origin: Origin = .manual,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.merchantKey = merchantKey
        self.direction = direction
        self.cadence = cadence
        self.amountPolicy = amountPolicy
        self.expectedAmount = expectedAmount
        self.currency = currency
        self.categoryID = categoryID
        self.nextExpectedDate = nextExpectedDate
        self.status = status
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Join: Transaktion ↔ Commitment (Roadmap #110). Ermöglicht dem Nutzer,
/// einzelne Buchungen zuzuordnen oder auszuschließen.
struct RecurringOccurrence: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let commitmentID: UUID
    let transactionID: UUID
    let createdAt: Date

    init(id: UUID = UUID(), commitmentID: UUID, transactionID: UUID, createdAt: Date = Date()) {
        self.id = id
        self.commitmentID = commitmentID
        self.transactionID = transactionID
        self.createdAt = createdAt
    }
}

enum RecurringPaymentMatcher {
    /// Paid-Matching (Roadmap #114 / WP4): Identity über den stabilen,
    /// normalisierten `merchantKey`, niemals über den Display-Namen.
    ///
    /// Umbenennen eines Commitments darf das Matching nicht brechen.
    /// Commitments ohne merchantKey (reine Manuell-Erfassung) werden NICHT
    /// heuristisch über Transaktionen gematcht; sie lösen sich über
    /// explizite Occurrences oder geplante Termine auf.
    static func matchingTransactions(
        for commitment: RecurringCommitment,
        in transactions: [Transaction],
        calendar: Calendar = .current
    ) -> [Transaction] {
        guard let rawKey = commitment.matchingMerchantKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawKey.isEmpty else {
            return []
        }
        let normalizedKey = CategoryRuleEngine.normalizedKey(rawKey)
        guard !normalizedKey.isEmpty else { return [] }
        // Eine Händler-ID steht nie im Buchungstext: Textvergleich unnötig.
        let keyIsMerchantID = UUID(uuidString: rawKey) != nil
        let cashflowPolicy = CashflowPolicy.shared

        let tolerance: Decimal = commitment.amountPolicy == .fixed
            ? max(Decimal(string: "0.50")!, commitment.expectedAmount * Decimal(string: "0.10")!)
            : commitment.expectedAmount // fluctuating: Betrag wirkt nicht als Kriterium

        return transactions.filter { txn in
            guard commitment.matchingAccountID == nil || txn.accountID == commitment.matchingAccountID else { return false }
            guard txn.amount.currency == commitment.currency else { return false }
            guard txn.status == .booked || txn.status == .pending else { return false }
            guard !cashflowPolicy.isExcluded(txn) else { return false }

            // Richtung
            switch (commitment.direction, cashflowPolicy.contribution(for: txn)) {
            case (.expense, .spending(let delta)) where delta > 0,
                 (.income, .income(let delta)) where delta > 0:
                break
            default:
                return false
            }

            // Betragstoleranz nur bei fixen Commitments, vor dem Händlervergleich.
            if commitment.amountPolicy == .fixed {
                let magnitude = abs(txn.amount.amount)
                guard abs(magnitude - commitment.expectedAmount) <= tolerance else { return false }
            }

            // Merchant-Signatur: normalisierter merchantKey muss im
            // Merchant-Namen der Transaktion enthalten sein (Varianten-
            // Normalisierung: "SPOTIFY AB" matcht Key "SPOTIFY"). Neben dem
            // Anzeigenamen zählen die unveränderten Bankfelder: Schlüssel aus
            // dem Rohtext ("MIETE MUSTERSTRASSE") greifen so auch, wenn der
            // Händler einen bereinigten Anzeigenamen trägt oder umbenannt wird.
            // Die Händler-ID ist billig, die Text-Normalisierung teuer: sie
            // läuft nur noch für Buchungen, die alle anderen Prüfungen bestehen.
            if txn.merchantID?.uuidString.caseInsensitiveCompare(rawKey) == .orderedSame { return true }
            guard !keyIsMerchantID else { return false }
            let merchantSignatures = [txn.effectiveMerchantName, txn.rawMerchantName, txn.rawDescription]
                .compactMap { $0 }
            return merchantSignatures.contains { CategoryRuleEngine.normalizedKey($0).contains(normalizedKey) }
        }
    }

    /// Nächster erwarteter Termin (#113): Aus dem letzten passenden Datum +
    /// Calendar-Cadence via RecurringScheduleService; ohne Historie aus dem
    /// gespeicherten nextExpectedDate.
    static func nextExpectedDate(
        for commitment: RecurringCommitment,
        matching transactions: [Transaction],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Date? {
        let matches = matchingTransactions(for: commitment, in: transactions, calendar: calendar)
        let lastMatchDate = matches
            .compactMap { $0.bookedAt ?? $0.authorizedAt }
            .max()

        if let last = lastMatchDate {
            return RecurringScheduleService().nextDate(
                after: last,
                cadence: commitment.cadence,
                calendar: calendar
            )
        }
        return commitment.nextExpectedDate
    }
}

/// Storage representation for a detected merchant on one account. No schema
/// mutation is needed, and old plain merchant signatures keep their semantics.
struct RecurringMerchantIdentity: Sendable {
    let accountID: UUID?
    let merchantKey: String
    private static let prefix = "account:v1:"

    init(accountID: UUID, merchantKey: String) {
        self.accountID = accountID
        self.merchantKey = merchantKey
    }

    init(persistedKey: String) {
        let parts = persistedKey.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        if persistedKey.hasPrefix(Self.prefix), parts.count == 2,
           let id = UUID(uuidString: String(parts[0].dropFirst(Self.prefix.count))) {
            accountID = id
            merchantKey = String(parts[1])
        } else {
            accountID = nil
            merchantKey = persistedKey
        }
    }

    var persistedKey: String {
        guard let accountID else { return merchantKey }
        return Self.prefix + accountID.uuidString + "|" + merchantKey
    }
}
