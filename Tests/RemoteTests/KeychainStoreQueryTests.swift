import Foundation
import Security
import Testing

@testable import FinanceTracker

/// Ohne ausdrückliches `kSecUseDataProtectionKeychain` wirkt SecItemDelete
/// bei einer App mit eigener Kennung auf beide Schlüsselbunde. In 0.5.3 hat
/// das Ausräumen des alten Eintrags nach dem Umzug so auch die neue Kopie
/// gelöscht. Jede Abfrage muss den Schlüsselbund deshalb benennen.
@Suite("KeychainStore-Abfragen")
struct KeychainStoreQueryTests {
    @Test("Jede Abfrage benennt den Schlüsselbund ausdrücklich")
    func queriesNameTheirKeychain() {
        let store = KeychainStore(service: "test")
        let legacy = store.query(account: "a", dataProtection: false)
        let modern = store.query(account: "a", dataProtection: true)
        #expect(legacy[kSecUseDataProtectionKeychain as String] as? Bool == false)
        #expect(modern[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }
}
