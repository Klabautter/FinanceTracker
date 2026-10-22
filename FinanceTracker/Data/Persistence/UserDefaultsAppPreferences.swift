import Foundation

/// `AppPreferences` auf UserDefaults: Schlüssel bleiben stabil, Werte sind
/// keine Secrets.
final class UserDefaultsAppPreferences: AppPreferences, @unchecked Sendable {
    static let cashWithdrawalTargetKey = "cashWithdrawalTargetAccountID"

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
}
