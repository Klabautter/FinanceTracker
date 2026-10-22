import Foundation

/// Nutzereinstellungen außerhalb der Datenbank (kein Backup-Inhalt, kein
/// Singleton: wird über `AppDependencies` verdrahtet).
protocol AppPreferences: Sendable {
    /// Bargeldkonto, dem erkannte Abhebungen automatisch gutgeschrieben
    /// werden. `nil` = Automatik aus.
    var cashWithdrawalTargetAccountID: UUID? { get }
    func setCashWithdrawalTargetAccountID(_ id: UUID?)
}

/// Flüchtige Variante für Tests und Previews.
final class InMemoryAppPreferences: AppPreferences, @unchecked Sendable {
    private let lock = NSLock()
    private var cashTarget: UUID?

    init(cashWithdrawalTargetAccountID: UUID? = nil) {
        cashTarget = cashWithdrawalTargetAccountID
    }

    var cashWithdrawalTargetAccountID: UUID? {
        lock.lock(); defer { lock.unlock() }
        return cashTarget
    }

    func setCashWithdrawalTargetAccountID(_ id: UUID?) {
        lock.lock(); defer { lock.unlock() }
        cashTarget = id
    }
}
