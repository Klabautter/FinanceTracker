import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("BankConnectModel")
struct BankConnectModelTests {
    private func makeDependencies() throws -> AppDependencies {
        let store = try SwiftDataStore(inMemory: true)
        return AppDependencies.make(container: store.container, baseCurrency: .eur)
    }

    private struct StaticProviderFactory: BankProviderResolving {
        let provider: any BankDataProvider
        func makeBankDataProvider() -> any BankDataProvider { provider }
    }

    private func sampleTxn(_ id: String, _ amount: String) -> RemoteBankTransaction {
        RemoteBankTransaction(
            externalID: id,
            state: .booked,
            amount: Money(amount: Decimal(string: amount)!, currency: .eur),
            bookingDate: Date(timeIntervalSince1970: 1_770_000_000),
            valueDate: nil,
            creditorName: "REWE MARKT",
            debtorName: nil,
            remittanceInformation: "Einkauf"
        )
    }

    @Test("Autorisierte Verbindung synchronisiert exakt einmal und zeigt echte Kontenanzahl")
    func syncRunsExactlyOnce() async throws {
        let dependencies = try makeDependencies()
        let credentials = InMemoryGoCardlessCredentialStore(secretID: "id-1", secretKey: "key-1")
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [
            sampleTxn("T1", "-43.27"),
            sampleTxn("T2", "-12.00")
        ]

        let model = BankConnectModel(
            kind: .gocardless,
            dependencies: dependencies,
            credentialStore: credentials,
            providerFactory: StaticProviderFactory(provider: provider)
        )
        #expect(credentials.readSecretID() == "id-1")

        // Credentials vorhanden -> Institutionen laden (Mock, kein Netzwerk)
        await model.loadStoredCredentialsIfNeeded()
        #expect(model.phase == .institutions || model.isLoadingInstitutions)

        // Verbindung starten (Requisition + Waiting-State)
        await model.startConnection(for: provider.stubbedInstitutions[0])
        guard case .waitingForAuthorization(let url, let name) = model.phase else {
            Issue.record("Expected waitingForAuthorization, got \(model.phase)")
            return
        }
        #expect(url != nil)
        #expect(name == "Sandbox Finance")

        // Autorisierung bestätigen -> GENAU EIN Sync
        await model.checkAuthorizationAndFinish()

        guard case .success(let accountsCreated) = model.phase else {
            Issue.record("Expected success, got \(model.phase)")
            return
        }
        #expect(accountsCreated == 1)
        #expect(provider.fetchAccountDataCallCount == 1, "Sync darf nur einmal laufen")

        let batches = try await dependencies.importBatchRepository.batches()
        #expect(batches.count == 1, "Doppelter Sync würde zwei Batches erzeugen")

        #expect(try await dependencies.transactionRepository.count() == 2)
    }

    @Test("Nicht autorisierte Verbindung: kein Sync, zurück zum Warten")
    func unauthorizedDoesNotSync() async throws {
        let dependencies = try makeDependencies()
        let credentials = InMemoryGoCardlessCredentialStore(secretID: "id-1", secretKey: "key-1")
        let provider = MockBankDataProvider()
        await provider.setAuthorization(.pending)

        let model = BankConnectModel(
            kind: .gocardless,
            dependencies: dependencies,
            credentialStore: credentials,
            providerFactory: StaticProviderFactory(provider: provider)
        )
        await model.startConnection(for: provider.stubbedInstitutions[0])
        await provider.setAuthorization(.pending)

        await model.checkAuthorizationAndFinish()

        guard case .waitingForAuthorization = model.phase else {
            Issue.record("Expected waiting state for unauthorized, got \(model.phase)")
            return
        }
        #expect(provider.fetchAccountDataCallCount == 0)
        #expect(try await dependencies.importBatchRepository.batches().isEmpty)
    }

    /// Sandbox-First (Spec: Bank Account Data Sandbox): Der Shortcut verbindet
    /// SANDBOXFINANCE_SFIN0000 direkt, ohne Institutionsliste, mit
    /// Mock-Bank-Hinweis, und läuft über denselben Sync-Pipeline-Pfad.
    @Test("Sandbox-Shortcut verbindet SANDBOXFINANCE_SFIN0000 direkt und synchronisiert")
    func sandboxShortcutStartsDirectConnection() async throws {
        let dependencies = try makeDependencies()
        let credentials = InMemoryGoCardlessCredentialStore(secretID: "sandbox-id", secretKey: "sandbox-key")
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [sampleTxn("S1", "-20.00")]

        let model = BankConnectModel(
            kind: .gocardless,
            dependencies: dependencies,
            credentialStore: credentials,
            providerFactory: StaticProviderFactory(provider: provider)
        )

        await model.startSandboxConnection()

        guard case .waitingForAuthorization(let url, let name) = model.phase else {
            Issue.record("Expected waitingForAuthorization, got \(model.phase)")
            return
        }
        #expect(name == "Sandbox Finance")
        #expect(model.isWaitingForSandbox, "Sandbox-Verbindung muss den Mock-Bank-Hinweis zeigen")
        #expect(BankConnectModel.isSandbox(provider.stubbedInstitutions[0]) == false, "Mock-Institution ist nicht die Sandbox")

        await model.checkAuthorizationAndFinish()

        guard case .success(let accountsCreated) = model.phase else {
            Issue.record("Expected success, got \(model.phase)")
            return
        }
        #expect(accountsCreated == 1)
        #expect(provider.fetchAccountDataCallCount == 1)
        #expect(try await dependencies.transactionRepository.count() == 1)
    }

    /// Enable-Banking-Code-Flow: startConnection → .codeExchange-Phase →
    /// Redirect-URL einfügen → Session → Sync (der produktive Weg).
    @Test("Enable Banking: Code-Exchange finalisiert die Verbindung und synchronisiert")
    func enableBankingCodeExchangeFlow() async throws {
        let dependencies = try makeDependencies()
        let credentials = InMemoryEnableBankingCredentialStore(
            applicationID: "app-1",
            privateKeyPEM: "test-key"
        )
        let provider = MockBankDataProvider()
        provider.identifier = ConnectionProvider.enablebanking.rawValue
        provider.stubbedTransactions = [sampleTxn("EB1", "-25.00")]

        let model = BankConnectModel(
            kind: .enablebanking,
            dependencies: dependencies,
            enableBankingCredentialStore: credentials,
            providerFactory: StaticProviderFactory(provider: provider)
        )
        await model.loadStoredCredentialsIfNeeded()
        #expect(model.phase == .institutions)

        await model.startConnection(for: provider.stubbedInstitutions[0])
        guard case .codeExchange(let authorizationID, let name, let authURL) = model.phase else {
            Issue.record("Expected codeExchange, got \(model.phase)")
            return
        }
        #expect(name == "Sandbox Finance")
        #expect(authURL != nil)

        await model.finishWithRedirectURL("https://example.com/redirect?state=x&code=abc123")

        guard case .success(let accountsCreated) = model.phase else {
            Issue.record("Expected success, got \(model.phase)")
            return
        }
        #expect(accountsCreated == 1)
        #expect(provider.fetchAccountDataCallCount == 1)

        // Connection muss dem Enable-Banking-Provider zugeordnet sein.
        let connections = try await dependencies.connectionRepository.connections()
        #expect(connections.first?.provider == .enablebanking)
        #expect(try await dependencies.transactionRepository.count() == 1)
    }

    /// Enable Banking: Redirect-URL ohne `code` → kontrollierter Fehler,
    /// kein stiller Abbruch (Rule 17).
    @Test("Enable Banking: Redirect-URL ohne Code → sichtbarer Fehler")
    func codeExchangeWithoutCodeFails() async throws {
        let dependencies = try makeDependencies()
        let credentials = InMemoryEnableBankingCredentialStore(
            applicationID: "app-1",
            privateKeyPEM: "test-key"
        )
        let provider = MockBankDataProvider()
        provider.identifier = ConnectionProvider.enablebanking.rawValue

        let model = BankConnectModel(
            kind: .enablebanking,
            dependencies: dependencies,
            enableBankingCredentialStore: credentials,
            providerFactory: StaticProviderFactory(provider: provider)
        )
        await model.startConnection(for: provider.stubbedInstitutions[0])

        await model.finishWithRedirectURL("https://example.com/redirect?state=ohne-code")

        guard case .failed(let message) = model.phase else {
            Issue.record("Expected failed, got \(model.phase)")
            return
        }
        #expect(message.contains("code"))
        #expect(provider.fetchAccountDataCallCount == 0)
    }

    @Test("Vorabprüfung: Sandbox, inaktiv und fehlende Redirect-URL werden benannt")
    func applicationWarnings() {
        let production = BankApplicationInfo(name: "Prod", environment: .production, isActive: true, redirectURLs: ["https://enablebanking.com/redirect"], countries: ["DE"])
        #expect(BankConnectModel.applicationWarnings(production, redirectURL: "https://enablebanking.com/redirect").isEmpty)

        let sandbox = BankApplicationInfo(name: "Test", environment: .sandbox, isActive: false, redirectURLs: [], countries: [])
        let warnings = BankConnectModel.applicationWarnings(sandbox, redirectURL: "https://enablebanking.com/redirect")
        #expect(warnings.count == 3)
        #expect(warnings[0].contains("Sandbox"))
        #expect(warnings[1].contains("inaktiv"))
        #expect(warnings[2].contains("Redirect-URL"))

        let failure = BankConnectModel.applicationCheckFailureMessage(BankProviderError.requestFailed(endpoint: "/application", status: 401, body: nil))
        #expect(failure.contains("HTTP 401"))
    }

    @Test("Credential-Löschung betrifft nur den gewählten Provider")
    func credentialDeletionIsProviderScoped() throws {
        let dependencies = try makeDependencies()
        let goCardless = InMemoryGoCardlessCredentialStore(secretID: "existing-id", secretKey: "existing-key")
        let enableBanking = InMemoryEnableBankingCredentialStore(
            applicationID: "existing-app",
            privateKeyPEM: "existing-pem"
        )
        let provider = MockBankDataProvider()
        let model = BankConnectModel(
            kind: .enablebanking,
            dependencies: dependencies,
            credentialStore: goCardless,
            enableBankingCredentialStore: enableBanking,
            providerFactory: StaticProviderFactory(provider: provider)
        )

        model.deleteCredentials()

        #expect(enableBanking.readApplicationID() == nil)
        #expect(enableBanking.readPrivateKey() == nil)
        #expect(goCardless.readSecretID() == "existing-id")
        #expect(goCardless.readSecretKey() == "existing-key")
        #expect(model.phase == .credentials)
    }

    @Test("Ältere Umsätze anfragen: neue Freigabe mit einem Jahr, alte leere Verbindung wird entfernt")
    func requestOlderTransactions() async throws {
        let dependencies = try makeDependencies()
        let provider = MockBankDataProvider()
        provider.stubbedTransactions = [sampleTxn("S1", "-20.00")]
        let old = Connection(
            id: UUID(),
            userID: UUID(),
            provider: .enablebanking,
            providerConnectionID: "old-session",
            institutionID: "DE|VR Bank Beispiel",
            status: .active,
            consentExpiresAt: nil,
            lastSuccessfulSyncAt: Date(),
            createdAt: Date(),
            updatedAt: Date()
        )
        try await dependencies.connectionRepository.upsert([old])

        let model = BankConnectModel(
            kind: .enablebanking,
            dependencies: dependencies,
            enableBankingCredentialStore: InMemoryEnableBankingCredentialStore(applicationID: "app", privateKeyPEM: "key"),
            providerFactory: StaticProviderFactory(provider: provider)
        )
        await model.requestOlderTransactions(for: old)

        #expect(model.isRequestingOlderTransactions)
        #expect(model.historyRange == .oneYear)
        guard case .codeExchange(_, let institutionName, _) = model.phase else {
            Issue.record("Erwartet: Freigabe-Schritt, war \(model.phase)")
            return
        }
        #expect(institutionName == "VR Bank Beispiel")

        await model.finishWithRedirectURL("https://enablebanking.com/redirect?code=abc")
        guard case .success = model.phase else {
            Issue.record("Erwartet: Erfolg, war \(model.phase)")
            return
        }
        #expect(provider.lastRequestedDateFrom != .some(nil))
        #expect(model.historyNotice != nil)

        let connections = try await dependencies.connectionRepository.connections()
        #expect(connections.count == 1)
        #expect(connections.first?.id != old.id)
        #expect(connections.first?.institutionID == "DE|VR Bank Beispiel")
    }
}
