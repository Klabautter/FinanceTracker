import Foundation

/// ViewModel für die „Aufteilen“-Sektion im Transaktionsdetail (P2,
/// Splitwise-light, #27/#28, kein PIS #15).
///
/// - Hält `SharedExpenseShare`s einer Transaktion (User-Sidecar, V12).
/// - Salden/Ausgleich je Währung via `GroupExpenseResolver` (#19/#35).
/// - Ausgleich wird ausschließlich als manuelle Transfer-Buchung
///   (`kind: .transfer`, neutral) angelegt, kein automatischer Versand.
///   Das Zielkonto wählt der Nutzer (Default: Transaktionskonto, #15).
/// - Kein MainActor-Blockieren: alles I/O via async Repository (@ModelActor).
@MainActor
@Observable
final class GroupExpenseSectionModel {
    let transaction: Transaction

    private let shareRepository: any SharedExpenseShareRepository
    private let transactionRepository: any TransactionRepository
    private let accountRepository: (any AccountRepository)?
    private let changeTracker: DataChangeTracker
    private let resolver = GroupExpenseResolver()

    private(set) var shares: [SharedExpenseShare] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    /// Wählbare Zielkonten für den Ausgleich (#15: manuell, kein
    /// Auto-Versand). Best-effort geladen, bleibt bei Fehlern leer und
    /// der Ausgleich fällt auf das Transaktionskonto zurück.
    private(set) var availableAccounts: [Account] = []
    /// Explizit gewähltes Ausgleichs-Zielkonto (nil = Transaktionskonto).
    var settlementAccountID: UUID?

    init(
        transaction: Transaction,
        dependencies: AppDependencies
    ) {
        self.transaction = transaction
        self.shareRepository = dependencies.sharedExpenseShareRepository
        self.transactionRepository = dependencies.transactionRepository
        self.accountRepository = dependencies.accountRepository
        self.changeTracker = dependencies.changeTracker
    }

    /// Test-Seam: explizite Repositories ohne vollen Container.
    init(
        transaction: Transaction,
        shareRepository: any SharedExpenseShareRepository,
        transactionRepository: any TransactionRepository,
        accountRepository: (any AccountRepository)? = nil,
        changeTracker: DataChangeTracker = DataChangeTracker()
    ) {
        self.transaction = transaction
        self.shareRepository = shareRepository
        self.transactionRepository = transactionRepository
        self.accountRepository = accountRepository
        self.changeTracker = changeTracker
    }

    var balances: [CurrencyCode: [String: Decimal]] {
        resolver.netBalances(shares: shares)
    }

    var transfers: [SettlementTransfer] {
        resolver.settlementTransfers(shares: shares)
    }

    var sortedCurrencies: [CurrencyCode] {
        balances.keys.sorted { $0.rawValue < $1.rawValue }
    }

    func balance(for person: String, currency: CurrencyCode) -> Decimal {
        balances[currency]?[person] ?? 0
    }

    var openShareCount: Int {
        shares.filter { !$0.settled }.count
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await shareRepository.shares(transactionID: transaction.id)
            shares = loaded.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        } catch {
            shares = []
            errorMessage = String(localized: "Anteile konnten nicht geladen werden.")
        }
        // Konten für den Ausgleichs-Picker (best-effort, #15): Ein Fehler
        // hier blockiert nicht die Anteile, Fallback ist Transaktionskonto.
        if let accountRepository {
            do {
                availableAccounts = try await accountRepository.accounts()
            } catch {
                availableAccounts = []
            }
        }
    }

    /// Fügt einen Anteil hinzu. Liefert true bei Erfolg, sonst false mit
    /// sichtbarer `errorMessage` (kein stiller Fallback, #17/#18).
    @discardableResult
    func addShare(paidBy: String, owedBy: String, amountText: String, currency: CurrencyCode) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        guard let amount = DecimalParser.parse(amountText), amount > 0 else {
            errorMessage = String(localized: "Bitte einen gültigen positiven Betrag eingeben.")
            return false
        }
        let payer = paidBy.trimmingCharacters(in: .whitespacesAndNewlines)
        let ower = owedBy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payer.isEmpty, !ower.isEmpty else {
            errorMessage = String(localized: "Bitte Zahler und Schuldner mit Namen angeben.")
            return false
        }
        guard payer != ower else {
            errorMessage = String(localized: "Zahler und Schuldner müssen unterschiedlich sein.")
            return false
        }
        // Mehr als die Ausgabe selbst kann niemand schulden.
        if currency == transaction.amount.currency {
            let alreadyShared = shares
                .filter { $0.shareCurrency == currency }
                .reduce(Decimal(0)) { $0 + $1.shareAmount }
            guard alreadyShared + amount <= abs(transaction.amount.amount) else {
                errorMessage = String(localized: "Die Anteile dürfen zusammen nicht mehr als den Betrag der Buchung ergeben.")
                return false
            }
        }

        let share: SharedExpenseShare
        do {
            share = try SharedExpenseShare(
                transactionID: transaction.id,
                paidBy: payer,
                owedBy: ower,
                shareAmount: amount,
                shareCurrency: currency
            )
        } catch let validation as GroupExpenseValidationError {
            errorMessage = switch validation {
            case .emptyParticipant: String(localized: "Bitte Zahler und Schuldner mit Namen angeben.")
            case .samePayerAndOwer: String(localized: "Zahler und Schuldner müssen unterschiedlich sein.")
            case .nonPositiveShare: String(localized: "Bitte einen positiven Anteil eingeben.")
            }
            return false
        } catch {
            errorMessage = String(localized: "Anteil konnte nicht angelegt werden.")
            return false
        }

        do {
            try await shareRepository.upsert([share])
            shares.append(share)
            shares.sort {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            changeTracker.markChanged()
            return true
        } catch {
            errorMessage = String(localized: "Anteil konnte nicht gespeichert werden.")
            return false
        }
    }

    func deleteShare(id: UUID) async {
        guard let index = shares.firstIndex(where: { $0.id == id }) else { return }
        let removed = shares.remove(at: index)
        do {
            try await shareRepository.delete(id: removed.id)
            changeTracker.markChanged()
        } catch {
            shares.insert(removed, at: min(index, shares.count))
            errorMessage = String(localized: "Anteil konnte nicht gelöscht werden.")
        }
    }

    func setSettled(id: UUID, settled: Bool) async {
        guard let index = shares.firstIndex(where: { $0.id == id }) else { return }
        var updated = shares[index]
        guard updated.settled != settled else { return }
        updated.settled = settled
        updated.updatedAt = Date()
        shares[index] = updated
        do {
            try await shareRepository.upsert([updated])
            changeTracker.markChanged()
        } catch {
            var reverted = updated
            reverted.settled = !settled
            shares[index] = reverted
            errorMessage = String(localized: "Status konnte nicht gespeichert werden.")
        }
    }

    /// Fabrik für die Ausgleichs-Buchung (#28: immer `.transfer`, neutral).
    /// Zielkonto: explizit übergeben oder via `settlementAccountID` gewählt,
    /// sonst das Transaktionskonto (Default, #15).
    func settlementTransaction(
        for transfer: SettlementTransfer,
        accountID: UUID? = nil
    ) -> Transaction {
        resolver.settlementTransaction(
            for: transfer,
            accountID: accountID ?? settlementAccountID ?? transaction.accountID
        )
    }

    /// Bucht den Ausgleich als manuelle Transfer-Buchung (mit Confirm in
    /// der View, kein PIS #15). Markiert Anteile bewusst NICHT automatisch
    /// als erledigt, das bleibt eine explizite Nutzer-Entscheidung.
    @discardableResult
    func bookSettlement(_ transfer: SettlementTransfer, accountID: UUID? = nil) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let booking = settlementTransaction(for: transfer, accountID: accountID)
            try await transactionRepository.upsert([booking])
            changeTracker.markChanged()
            return true
        } catch {
            errorMessage = String(localized: "Ausgleich konnte nicht als Transfer gebucht werden.")
            return false
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
