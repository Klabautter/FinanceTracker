import Foundation

/// Bargeldabhebung als Umbuchung: Die Bankbuchung (z. B. „GELDAUTOMAT −100")
/// wird zum Transfer, und das Bargeldkonto bekommt eine Gegenbuchung
/// (+100, Transfer). Die Bankbuchung bleibt Provider-Fakt: der Typ wird nur
/// per Annotation überstimmt, die Gegenbuchung ist manuell.
///
/// Idempotent: Die Gegenbuchung trägt eine stabile externalID aus der
/// Quell-ID; ein zweiter Aufruf legt nichts doppelt an.
struct MirrorCashWithdrawal: Sendable {
    enum Outcome: Equatable, Sendable {
        case created(Transaction)
        case alreadyMirrored
        case currencyMismatch
        case notEligible
    }

    static let merchantName = "Bargeldabhebung"

    let transactionRepository: any TransactionRepository
    let annotationRepository: any TransactionAnnotationRepository
    let accountRepository: any AccountRepository
    let preferences: any AppPreferences

    static func mirrorExternalID(for source: Transaction) -> String {
        "cash-mirror:\(source.id.uuidString)"
    }

    /// Manuell ausgelöst (Kontextmenü): `source` muss eine Ausgabe auf einem
    /// anderen Konto sein; Erkennungs-Stichwörter sind hier nicht nötig.
    func mirror(_ source: Transaction, into cash: Account, sourceAccountName: String) async throws -> Outcome {
        guard source.amount.isNegative, source.accountID != cash.id,
              source.status != .reversed, source.status != .cancelled else { return .notEligible }
        guard source.amount.currency == cash.currency else { return .currencyMismatch }

        let externalID = Self.mirrorExternalID(for: source)
        var query = TransactionQuery()
        query.accountIDs = [cash.id]
        query.sources = [.manual]
        let existing = try await transactionRepository.transactions(matching: query)
        if existing.contains(where: { $0.externalID == externalID }) {
            return .alreadyMirrored
        }

        let amount = Money(amount: abs(source.amount.amount), currency: cash.currency)
        let date = source.displayDate
        let counterpart = Transaction(
            accountID: cash.id,
            source: .manual,
            externalID: externalID,
            sourceFingerprint: TransactionFingerprinter.fingerprint(
                source: .manual,
                accountID: cash.id,
                bookingDate: date,
                amount: amount,
                merchantOrDescription: Self.merchantName
            ),
            status: .booked,
            kind: .transfer,
            amount: amount,
            bookedAt: date,
            rawDescription: "\(Self.merchantName) · \(sourceAccountName)",
            rawMerchantName: Self.merchantName,
            merchantDisplayName: Self.merchantName,
            categoryID: Category.transfers.id,
            paymentMethod: .cash
        )
        try await transactionRepository.upsert([counterpart])

        var annotation = try await annotationRepository.annotation(transactionID: source.id)
            ?? TransactionAnnotation.legacyFallback(for: source)
        annotation.manualKindOverride = .transfer
        annotation.updatedAt = Date()
        try await annotationRepository.upsert([annotation])
        return .created(counterpart)
    }

    /// Automatik nach Sync/Import: alle erkannten Abhebungen unter den
    /// `candidates` ins eingestellte Bargeldkonto spiegeln. Ohne Einstellung
    /// oder ohne aktives Bargeldkonto passiert nichts. Liefert die Anzahl
    /// neuer Gegenbuchungen.
    @discardableResult
    func mirrorDetectedWithdrawals(in candidates: [Transaction]) async throws -> Int {
        guard let targetID = preferences.cashWithdrawalTargetAccountID else { return 0 }
        let accounts = try await accountRepository.accounts()
        guard let cash = accounts.first(where: { $0.id == targetID }), cash.isActive, cash.type == .cash else { return 0 }
        let namesByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        var created = 0
        for candidate in candidates where candidate.accountID != cash.id && CashWithdrawalDetector.isWithdrawal(candidate) {
            if case .created = try await mirror(candidate, into: cash, sourceAccountName: namesByID[candidate.accountID] ?? "Konto") {
                created += 1
            }
        }
        return created
    }
}
