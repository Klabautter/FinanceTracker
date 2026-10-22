import Foundation

/// Trennt genau eine Bankverbindung. Ihre Konten bleiben mit allen Buchungen
/// erhalten, werden aber nicht mehr abgerufen („Getrennte Konten"). Andere
/// Verbindungen und die Zugangsdaten des Anbieters bleiben unberührt.
struct DisconnectBankConnection: Sendable {
    let accountRepository: any AccountRepository
    let connectionRepository: any ConnectionRepository

    func callAsFunction(_ connection: Connection) async throws {
        for var account in try await accountRepository.accounts()
        where account.connectionID == connection.id {
            account.isActive = false
            account.connectionID = nil
            try await accountRepository.upsert([account])
        }
        try await connectionRepository.delete(id: connection.id)
    }
}
