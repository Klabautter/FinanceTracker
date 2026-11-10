import Foundation

/// Nutzereinstellungen außerhalb der Datenbank (kein Backup-Inhalt, kein
/// Singleton: wird über `AppDependencies` verdrahtet).
protocol AppPreferences: Sendable {
    /// Bargeldkonto, dem erkannte Abhebungen automatisch gutgeschrieben
    /// werden. `nil` = Automatik aus.
    var cashWithdrawalTargetAccountID: UUID? { get }
    func setCashWithdrawalTargetAccountID(_ id: UUID?)
    /// Verbundene Banken beim Öffnen der App und danach in Abständen von
    /// selbst abrufen. Standard: an.
    var automaticBankSyncEnabled: Bool { get }
    func setAutomaticBankSyncEnabled(_ enabled: Bool)
}

/// Flüchtige Variante für Tests und Previews.
final class InMemoryAppPreferences: AppPreferences, @unchecked Sendable {
    private let lock = NSLock()
    private var cashTarget: UUID?
    private var automaticBankSync: Bool

    init(cashWithdrawalTargetAccountID: UUID? = nil, automaticBankSyncEnabled: Bool = true) {
        cashTarget = cashWithdrawalTargetAccountID
        automaticBankSync = automaticBankSyncEnabled
    }

    var cashWithdrawalTargetAccountID: UUID? {
        lock.lock(); defer { lock.unlock() }
        return cashTarget
    }

    func setCashWithdrawalTargetAccountID(_ id: UUID?) {
        lock.lock(); defer { lock.unlock() }
        cashTarget = id
    }

    var automaticBankSyncEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return automaticBankSync
    }

    func setAutomaticBankSyncEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        automaticBankSync = enabled
    }
}
