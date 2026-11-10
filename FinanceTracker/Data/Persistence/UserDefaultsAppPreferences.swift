import Foundation

/// `AppPreferences` auf UserDefaults: Schlüssel bleiben stabil, Werte sind
/// keine Secrets.
final class UserDefaultsAppPreferences: AppPreferences, @unchecked Sendable {
    static let cashWithdrawalTargetKey = "cashWithdrawalTargetAccountID"
    static let automaticBankSyncKey = "automaticBankSyncEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var cashWithdrawalTargetAccountID: UUID? {
        defaults.string(forKey: Self.cashWithdrawalTargetKey).flatMap(UUID.init(uuidString:))
    }

    func setCashWithdrawalTargetAccountID(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Self.cashWithdrawalTargetKey)
        } else {
            defaults.removeObject(forKey: Self.cashWithdrawalTargetKey)
        }
    }

    /// Ohne gespeicherten Wert gilt der Standard: an.
    var automaticBankSyncEnabled: Bool {
        defaults.object(forKey: Self.automaticBankSyncKey) as? Bool ?? true
    }

    func setAutomaticBankSyncEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.automaticBankSyncKey)
    }
}
