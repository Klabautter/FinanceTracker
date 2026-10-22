import Foundation

@MainActor
@Observable
final class BankConnectModel {
    /// GoCardless Sandbox Finance (Spec: Bank Account Data Sandbox):
    /// Mock-Bank für den kompletten Integrationstest ohne PSD2-Login:
    /// beliebige Werte für User-ID und Code-Generator im Auth-Flow.
    static let sandboxInstitutionID = "SANDBOXFINANCE_SFIN0000"

    static let sandboxInstitution = BankInstitution(
        id: sandboxInstitutionID,
        name: "Sandbox Finance",
        bic: nil,
        transactionTotalDays: 90
    )

    /// Aggregator-Auswahl: Enable Banking (Production oder Sandbox);
    /// GoCardless-Sign-ups sind eingefroren, der Provider bleibt als Code
    /// erhalten. Salt Edge später über denselben `BankDataProvider`-Slot.
    enum ProviderKind: String, CaseIterable {
        case enablebanking
        case gocardless

        var displayName: String {
            switch self {
            case .enablebanking: "Enable Banking"
            case .gocardless: "GoCardless"
            }
        }
    }

    enum Phase: Equatable {
        case credentials
        case institutions
        case connecting
        /// GoCardless: Nutzer autorisiert in der Bank, dann Status-Check.
        case waitingForAuthorization(url: URL?, institutionName: String)
        /// Enable Banking: Redirect-URL mit `?code=` zurück in die App
        /// einfügen (`POST /sessions`).
        case codeExchange(authorizationID: String, institutionName: String, authURL: URL?)
        case checking
        case success(accountsCreated: Int)
        case failed(String)
    }

    private let dependencies: AppDependencies
    private let credentialStore: any GoCardlessCredentialStoring
    private let enableBankingCredentialStore: any EnableBankingCredentialStoring
    private let providerFactory: any BankProviderResolving

    let kind: ProviderKind
    private(set) var phase: Phase = .credentials

    // GoCardless
    var secretIDInput: String = ""
    var secretKeyInput: String = ""

    // Enable Banking
    var applicationIDInput: String = ""
    var privateKeyInput: String = ""
    /// Redirect-URL, die im Control Panel registriert ist (Dev-Flow: Nutzer
    /// fügt die finale Browser-URL hier ein).
    var redirectURLInput: String = "https://enablebanking.com/redirect"

    var country: String = "DE"
    var searchText: String = ""

    private(set) var institutions: [BankInstitution] = []
    private(set) var isLoadingInstitutions = false

    private var selectedInstitution: BankInstitution?
    private var pendingConnectionID: String?
    private var pendingAuthorizationURL: URL?
    private let provider: any BankDataProvider

    // MARK: - Consent-Health (P1, PSD2 read-only)

    /// Reine Consent-Auswertung (T-10d-Banner, SCA ≤180d), kein Netzwerk,
    /// kein Singleton.
    private let healthEvaluator = ConnectionHealthEvaluator()

    private(set) var connections: [Connection] = []
    private(set) var isLoadingConnections = false
    private(set) var connectionsErrorMessage: String?
    private(set) var syncingConnectionID: UUID?
    /// 3-Wege-Sync-Fehler pro Connection (silent-retry vs. Re-Auth vs. blockiert).
    private(set) var syncIssues: [UUID: SyncFailureKind] = [:]
    private(set) var syncIssueMessages: [UUID: String] = [:]
    private(set) var lastSyncNotice: String?

    // MARK: - Vorabprüfung der Anwendung (Production-Banklauf)

    /// Ergebnis von `GET /application`: Umgebung, Aktivierung, Redirect-URLs.
    private(set) var applicationInfo: BankApplicationInfo?
    private(set) var applicationCheckMessage: String?
    private(set) var isCheckingApplication = false

    init(
        kind: ProviderKind = .enablebanking,
        dependencies: AppDependencies,
        credentialStore: any GoCardlessCredentialStoring = KeychainGoCardlessCredentialStore(),
        enableBankingCredentialStore: (any EnableBankingCredentialStoring)? = nil,
        providerFactory: (any BankProviderResolving)? = nil
    ) {
        self.kind = kind
        self.dependencies = dependencies
        self.credentialStore = credentialStore
        let enableBankingCredentialStore = enableBankingCredentialStore ?? dependencies.enableBankingCredentialStore
        self.enableBankingCredentialStore = enableBankingCredentialStore
        switch kind {
        case .enablebanking:
            self.providerFactory = providerFactory ?? EnableBankingProviderFactory(
                redirectURL: EnableBankingProviderFactory.defaultRedirectURL,
                credentialStore: enableBankingCredentialStore
            )
        case .gocardless:
            self.providerFactory = providerFactory ?? GoCardlessPoCProviderFactory(
                credentialStore: credentialStore
            )
        }
        self.provider = self.providerFactory.makeBankDataProvider()
    }

    // MARK: - Zeitraum der Umsätze

    /// Wie weit der erste Abruf nach dem Verbinden zurückgehen soll.
    enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
        case bankDefault
        case oneYear
        case twoYears

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bankDefault: String(localized: "Standard der Bank (meist 90 Tage)")
            case .oneYear: String(localized: "Ein Jahr")
            case .twoYears: String(localized: "Zwei Jahre")
            }
        }

        /// `nil` = kein Startdatum mitschicken, die Bank entscheidet.
        func startDate(now: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .bankDefault: nil
            case .oneYear: calendar.date(byAdding: .year, value: -1, to: calendar.startOfDay(for: now))
            case .twoYears: calendar.date(byAdding: .year, value: -2, to: calendar.startOfDay(for: now))
            }
        }
    }

    var historyRange: HistoryRange = .bankDefault

    /// Was nach dem Verbinden tatsächlich geliefert wurde, ehrlich, auch
    /// wenn die Bank weniger herausgibt als angefragt.
    private(set) var historyNotice: String?

    /// Wofür eine bestehende Verbindung gerade neu freigegeben wird.
    enum RenewalPurpose: Sendable, Equatable {
        /// Freigabe verlängern (läuft bald ab oder ist abgelaufen).
        case reauthorize
        /// Längeren Zeitraum laden: braucht ebenfalls eine frische Freigabe.
        case olderTransactions
    }

    private(set) var renewalPurpose: RenewalPurpose?

    /// Bis wann die Bank den Lesezugriff nach dem Verbinden erlaubt.
    private(set) var consentValidUntil: Date?

    /// Ob gerade ältere Umsätze für eine bestehende Verbindung angefragt werden.
    var isRequestingOlderTransactions: Bool { renewalPurpose == .olderTransactions }

    nonisolated static func historyNotice(requestedStart: Date?, earliestDelivered: Date?) -> String? {
        guard let earliestDelivered else {
            return requestedStart == nil ? nil : String(localized: "Die Bank hat für diesen Zeitraum keine Umsätze geliefert.")
        }
        let delivered = AppDateFormatter.day(earliestDelivered)
        guard let requestedStart else {
            return String(localized: "Umsätze ab \(delivered) geladen.")
        }
        // Ein Monat Spielraum: Ein Konto ohne Umsätze in den ersten Wochen
        // des Zeitraums ist keine Kürzung durch die Bank.
        let tolerance: TimeInterval = 31 * 24 * 60 * 60
        if earliestDelivered.timeIntervalSince(requestedStart) > tolerance {
            return String(localized: "Angefragt ab \(AppDateFormatter.day(requestedStart)), die Bank hat Umsätze ab \(delivered) geliefert. Ältere Monate kannst du per Datei-Import ergänzen.")
        }
        return String(localized: "Umsätze ab \(delivered) geladen.")
    }

    /// Für eine bestehende Verbindung ältere Umsätze holen: Das geht nur mit
    /// einer frischen Freigabe bei der Bank; viele Banken geben mehr als 90
    /// Tage nur direkt nach der Anmeldung heraus. Konten und bereits
    /// vorhandene Buchungen werden dabei wiederverwendet, nicht dupliziert.
    func requestOlderTransactions(for connection: Connection) async {
        await renew(connection, purpose: .olderTransactions)
    }

    /// Freigabe einer bestehenden Verbindung erneuern, mit der vollen
    /// Laufzeit, die die Bank erlaubt. Der Zeitraum bleibt wählbar.
    func reauthorize(_ connection: Connection) async {
        await renew(connection, purpose: .reauthorize)
    }

    private func renew(_ connection: Connection, purpose: RenewalPurpose) async {
        guard kind == .enablebanking,
              let institutionID = connection.institutionID,
              let name = institutionID.split(separator: "|", maxSplits: 1).last.map(String.init),
              !name.isEmpty else { return }
        renewalPurpose = purpose
        if purpose == .olderTransactions, historyRange == .bankDefault { historyRange = .oneYear }
        let institution = institutions.first { $0.id == institutionID }
            ?? BankInstitution(id: institutionID, name: name, bic: nil, transactionTotalDays: nil)
        await startConnection(for: institution)
    }

    /// Nach einer neuen Freigabe für dieselbe Bank hängen die Konten an der
    /// neuen Verbindung; die alte ist leer und wird entfernt, damit die Bank
    /// nicht doppelt in der Liste steht.
    private func removeSupersededConnections(keeping connection: Connection) async {
        do {
            let accounts = try await dependencies.accountRepository.accounts()
            let usedConnectionIDs = Set(accounts.compactMap(\.connectionID))
            let superseded = try await dependencies.connectionRepository.connections().filter {
                $0.id != connection.id
                    && $0.provider == connection.provider
                    && $0.institutionID == connection.institutionID
                    && !usedConnectionIDs.contains($0.id)
            }
            for old in superseded {
                try await dependencies.connectionRepository.delete(id: old.id)
            }
        } catch {
            // Aufräumen ist Zusatz; die neue Verbindung steht bereits.
        }
    }

    // MARK: - Geführte Einrichtung (Enable Banking)

    static let controlPanelURL = URL(string: "https://enablebanking.com/cp/applications")!

    /// Datenschutz- und Nutzungsbedingungen der App (PRIVACY.md/TERMS.md im
    /// Repository), gleich für alle Installationen, deshalb kann jeder sie
    /// in seiner Enable-Banking-Anwendung eintragen.
    static let privacyPolicyURL: String? = "https://github.com/Klabautter/FinanceTracker/blob/main/PRIVACY.md"
    static let termsURL: String? = "https://github.com/Klabautter/FinanceTracker/blob/main/TERMS.md"

    /// Muss in der Enable-Banking-Anwendung als Redirect-URL stehen.
    static var setupRedirectURL: String { EnableBankingProviderFactory.defaultRedirectURL }

    /// Rückmeldung zur geladenen Schlüsseldatei (Erfolg oder Problem).
    private(set) var keyFileMessage: String?
    private(set) var keyFileLoaded = false

    /// Das Control Panel speichert den Schlüssel als „<Application ID>.pem".
    /// Liefert die ID, wenn der Dateiname so aussieht.
    nonisolated static func applicationID(fromKeyFileName fileName: String) -> String? {
        let stem = (fileName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Browser hängen bei doppeltem Download „ (1)" an.
        let base = stem.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        return UUID(uuidString: base) != nil ? base.lowercased() : nil
    }

    /// Ob der eingegebene Schlüssel ein lesbarer privater Schlüssel ist.
    var privateKeyInputIsValid: Bool {
        let trimmed = privateKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && (try? EnableBankingJWTSigner.loadPrivateKey(pem: trimmed)) != nil
    }

    var canSaveEnableBankingCredentials: Bool {
        !applicationIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && privateKeyInputIsValid
    }

    /// Lädt die vom Control Panel heruntergeladene .pem-Datei. Die
    /// Application ID wird aus dem Dateinamen übernommen, wenn das Feld noch
    /// leer ist.
    func importPrivateKeyFile(at url: URL) async {
        let content: String?
        do {
            content = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                // Ein Schlüssel ist wenige KB groß; alles Größere ist keiner.
                guard data.count < 64 * 1_024 else { return nil }
                return String(data: data, encoding: .utf8)
            }.value
        } catch {
            content = nil
        }
        guard let pem = content?.trimmingCharacters(in: .whitespacesAndNewlines),
              (try? EnableBankingJWTSigner.loadPrivateKey(pem: pem)) != nil else {
            keyFileLoaded = false
            keyFileMessage = String(localized: "Diese Datei enthält keinen lesbaren privaten Schlüssel. Wähle die .pem-Datei, die beim Anlegen der Anwendung heruntergeladen wurde.")
            return
        }
        privateKeyInput = pem
        keyFileLoaded = true
        if applicationIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let applicationID = Self.applicationID(fromKeyFileName: url.lastPathComponent) {
            applicationIDInput = applicationID
            keyFileMessage = String(localized: "Schlüssel geladen, Application ID aus dem Dateinamen übernommen.")
        } else {
            keyFileMessage = String(localized: "Schlüssel geladen.")
        }
    }

    func keyFileSelectionFailed() {
        keyFileLoaded = false
        keyFileMessage = String(localized: "Die Datei konnte nicht geöffnet werden.")
    }

    /// Ob gerade geprüft wird, ob Zugangsdaten im Schlüsselbund liegen.
    private(set) var isLoadingStoredCredentials = false

    /// Liest den Schlüsselbund im Hintergrund: Wartet macOS dort auf die
    /// Freigabe durch den Nutzer, bleibt die App bedienbar.
    func loadStoredCredentialsIfNeeded() async {
        guard phase == .credentials, !isLoadingStoredCredentials else { return }
        isLoadingStoredCredentials = true
        defer { isLoadingStoredCredentials = false }
        switch kind {
        case .gocardless:
            let store = credentialStore
            let hasCredentials = await Task.detached {
                store.readSecretID() != nil && store.readSecretKey() != nil
            }.value
            guard hasCredentials, phase == .credentials else { return }
            phase = .institutions
            await loadInstitutions()
        case .enablebanking:
            let store = enableBankingCredentialStore
            let hasCredentials = await Task.detached {
                store.readApplicationID() != nil && store.readPrivateKey() != nil
            }.value
            guard hasCredentials, phase == .credentials else { return }
            phase = .institutions
            await loadInstitutions()
            await checkApplication()
        }
    }

    /// Prüft Zugangsdaten und Setup der Anwendung ohne Bankkontakt. Fehler
    /// blockieren den Ablauf nicht, werden aber sichtbar gemacht.
    func checkApplication() async {
        guard kind == .enablebanking, let checker = provider as? BankApplicationInfoProviding else { return }
        guard !isCheckingApplication else { return }
        isCheckingApplication = true
        defer { isCheckingApplication = false }
        applicationCheckMessage = nil
        do {
            let info = try await checker.applicationInfo()
            applicationInfo = info
            BankSyncService.logger.info("Anwendung geprüft: \(String(describing: info.environment), privacy: .public), aktiv=\(info.isActive, privacy: .public), \(info.redirectURLs.count, privacy: .public) Redirect-URLs")
        } catch {
            applicationInfo = nil
            applicationCheckMessage = Self.applicationCheckFailureMessage(error)
            BankSyncService.logger.error("Anwendungsprüfung fehlgeschlagen: \(BankSyncService.describe(error), privacy: .public)")
        }
    }

    static func applicationCheckFailureMessage(_ error: Error) -> String {
        if case BankProviderError.requestFailed(_, let status, _) = error {
            if status == 401 || status == 403 {
                return String(localized: "Enable Banking lehnt die Zugangsdaten ab (HTTP \(status)). Application ID und privater Schlüssel passen nicht zusammen, oder die Anwendung ist gesperrt.")
            }
            return String(localized: "Die Anwendung konnte nicht geprüft werden (HTTP \(status)).")
        }
        return String(localized: "Die Anwendung konnte nicht geprüft werden. Prüfe die Internetverbindung.")
    }

    /// Hinweise vor dem echten Banklauf: reine Darstellung, testbar.
    static func applicationWarnings(_ info: BankApplicationInfo, redirectURL: String) -> [String] {
        var warnings: [String] = []
        switch info.environment {
        case .sandbox:
            warnings.append(String(localized: "Sandbox-Anwendung: Es kommen nur Testdaten (Mock ASPSP), keine echten Konten."))
        case .unknown(let raw):
            warnings.append(String(localized: "Unbekannte Umgebung „\(raw)“. Bitte im Control Panel prüfen."))
        case .production:
            break
        }
        if !info.isActive {
            warnings.append(String(localized: "Die Anwendung ist inaktiv. Im Control Panel „Activate by linking accounts“ für die eigenen Konten ausführen."))
        }
        let trimmed = redirectURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !info.redirectURLs.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }) {
            warnings.append(String(localized: "Die Redirect-URL \(trimmed) ist in der Anwendung nicht hinterlegt, die Bank-Autorisierung würde scheitern."))
        }
        return warnings
    }

    var applicationWarnings: [String] {
        applicationInfo.map { Self.applicationWarnings($0, redirectURL: redirectURLInput) } ?? []
    }

    static func environmentLabel(_ environment: BankApplicationInfo.Environment) -> String {
        switch environment {
        case .production: "Production"
        case .sandbox: "Sandbox"
        case .unknown(let raw): raw.isEmpty ? String(localized: "Unbekannt") : raw
        }
    }

    func saveCredentialsAndContinue() async {
        switch kind {
        case .gocardless:
            let trimmedID = secretIDInput.trimmingCharacters(in: .whitespaces)
            let trimmedKey = secretKeyInput.trimmingCharacters(in: .whitespaces)
            guard !trimmedID.isEmpty, !trimmedKey.isEmpty else {
                phase = .failed(String(localized: "Bitte beide Felder ausfüllen."))
                return
            }
            do {
                try credentialStore.save(secretID: trimmedID, secretKey: trimmedKey)
                secretIDInput = ""
                secretKeyInput = ""
                phase = .institutions
                await loadInstitutions()
            } catch {
                phase = .failed(String(localized: "Die Zugangsdaten konnten nicht gespeichert werden."))
            }

        case .enablebanking:
            let trimmedAppID = applicationIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedKey = privateKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAppID.isEmpty, !trimmedKey.isEmpty else {
                phase = .failed(String(localized: "Bitte Application ID und privaten Schlüssel einfügen."))
                return
            }
            // Schlüssel validieren BEVOR er gespeichert wird: ein kaputter
            // PEM soll nicht erst beim Auth-Aufruf auffallen.
            do {
                _ = try EnableBankingJWTSigner.loadPrivateKey(pem: trimmedKey)
            } catch {
                phase = .failed(String(localized: "Der private Schlüssel konnte nicht gelesen werden. Bitte die komplette .pem-Datei (inkl. BEGIN/END-Zeilen) einfügen."))
                return
            }
            do {
                try enableBankingCredentialStore.save(applicationID: trimmedAppID, privateKeyPEM: trimmedKey)
                applicationIDInput = ""
                privateKeyInput = ""
                phase = .institutions
                await loadInstitutions()
                await checkApplication()
            } catch {
                phase = .failed(String(localized: "Die Zugangsdaten konnten nicht gespeichert werden."))
            }
        }
    }

    /// Banken, die vom Löschen des Anbieter-Schlüssels betroffen wären; der
    /// Schlüssel gilt für alle Verbindungen dieses Anbieters.
    var banksUsingCredentials: [String] {
        let provider: ConnectionProvider = kind == .enablebanking ? .enablebanking : .gocardless
        return connections.filter { $0.provider == provider }.map(\.displayName)
    }

    func deleteCredentials() {
        applicationInfo = nil
        applicationCheckMessage = nil
        switch kind {
        case .enablebanking:
            enableBankingCredentialStore.deleteAll()
        case .gocardless:
            credentialStore.deleteAll()
        }
        applicationIDInput = ""
        privateKeyInput = ""
        secretIDInput = ""
        secretKeyInput = ""
        phase = .credentials
    }

    func loadInstitutions() async {
        let requestedCountry = country
        let cache = dependencies.bankInstitutionCache
        if let cached = await cache.institutions(provider: kind.rawValue, country: requestedCountry) {
            institutions = cached
            return
        }
        institutions = []
        isLoadingInstitutions = true
        defer { isLoadingInstitutions = false }

        do {
            let loaded = try await provider.institutions(country: requestedCountry)
            await cache.store(loaded, provider: kind.rawValue, country: requestedCountry)
            // Wurde inzwischen ein anderes Land gewählt, gilt dessen Liste.
            guard country == requestedCountry else { return }
            institutions = loaded
        } catch {
            phase = .failed(String(localized: "Die Banken konnten nicht geladen werden. Prüfe die Internetverbindung."))
        }
    }

    // MARK: - Bankauswahl

    /// Ohne Suche: die bekanntesten Banken des Landes statt tausender Zeilen.
    var popularInstitutions: [BankInstitution] {
        BankInstitutionSearch.popular(in: institutions, country: country)
    }

    /// „Sparkasse", „Volksbank" …: starten die Suche statt eine Filiale zu raten.
    var groupShortcuts: [String] {
        BankInstitutionSearch.groupShortcuts(in: institutions, country: country)
    }

    var searchResult: BankInstitutionSearch.Result {
        BankInstitutionSearch.search(searchText, in: institutions)
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Länder der eigenen Anwendung (laut Enable Banking), sonst eine
    /// Auswahl der Länder, die der Anbieter abdeckt.
    var availableCountries: [String] {
        let fromApplication = applicationInfo?.countries.map { $0.uppercased() } ?? []
        var codes = fromApplication.isEmpty ? Self.defaultCountries : fromApplication
        if !codes.contains(country) { codes.append(country) }
        return codes.sorted { Self.countryName($0).localizedCompare(Self.countryName($1)) == .orderedAscending }
    }

    static let defaultCountries = [
        "AT", "BE", "CH", "CZ", "DE", "DK", "EE", "ES", "FI", "FR", "GB", "IE",
        "IT", "LT", "LU", "LV", "NL", "NO", "PL", "PT", "SE"
    ]

    static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// Wählt ein anderes Land und lädt dessen Banken.
    func selectCountry(_ code: String) async {
        guard code != country else { return }
        country = code
        searchText = ""
        await loadInstitutions()
    }

    /// Ob für diese Bank schon eine Verbindung besteht.
    func isConnected(_ institution: BankInstitution) -> Bool {
        connections.contains { $0.institutionID == institution.id }
    }

    // MARK: - Eine Verbindung trennen

    /// Trennt nur diese Bank. Ihre Konten und Buchungen bleiben erhalten,
    /// die Zugangsdaten des Anbieters und andere Banken bleiben unberührt.
    func disconnect(_ connection: Connection) async {
        do {
            try await DisconnectBankConnection(
                accountRepository: dependencies.accountRepository,
                connectionRepository: dependencies.connectionRepository
            )(connection)
            syncIssues[connection.id] = nil
            syncIssueMessages[connection.id] = nil
            lastSyncNotice = String(localized: "\(connection.displayName) getrennt. Die Konten findest du unter „Getrennte Konten“.")
            dependencies.changeTracker.markChanged()
            await loadConnections()
        } catch {
            connectionsErrorMessage = String(localized: "\(connection.displayName) konnte nicht getrennt werden.")
        }
    }

    func startConnection(for institution: BankInstitution) async {
        selectedInstitution = institution
        phase = .connecting

        do {
            let result = try await provider.createConnection(institutionID: institution.id, redirectURL: nil)
            pendingConnectionID = result.connectionID
            pendingAuthorizationURL = result.authorizationURL
            switch kind {
            case .gocardless:
                phase = .waitingForAuthorization(url: result.authorizationURL, institutionName: institution.name)
            case .enablebanking:
                phase = .codeExchange(
                    authorizationID: result.connectionID,
                    institutionName: institution.name,
                    authURL: result.authorizationURL
                )
            }
        } catch {
            phase = .failed(String(localized: "Die Verbindung zur Bank konnte nicht initialisiert werden."))
        }
    }

    /// Sandbox-First-Shortcut (GoCardless-Sandbox ist pausiert; der
    /// Shortcut bleibt für Bestands-Keys erhalten).
    func startSandboxConnection() async {
        await startConnection(for: Self.sandboxInstitution)
    }

    /// UI-Hinweis im Warte-Screen: Sandbox nutzt den Mock-Bank-Login.
    var isWaitingForSandbox: Bool {
        selectedInstitution.map(Self.isSandbox) ?? false
    }

    /// `true`, wenn die Institution die GoCardless Sandbox ist; die UI
    /// zeigt dann Mock-Bank-Hinweise statt PSD2-Login-Erwartung.
    static func isSandbox(_ institution: BankInstitution) -> Bool {
        institution.id == sandboxInstitutionID
    }

    // MARK: - Enable Banking: Code-Exchange

    /// Extrahiert den `code` aus der eingefügten Redirect-URL (nimmt die
    /// letzte URL im Text) und finalisiert die Verbindung.
    func finishWithRedirectURL(_ text: String) async {
        guard pendingConnectionID != nil,
              let institution = selectedInstitution else { return }

        guard let url = Self.firstURL(in: text),
              let code = url.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            phase = .failed(String(localized: "In der eingefügten URL fehlt der Parameter „code“. Bitte die komplette URL nach der Bank-Autorisierung einfügen."))
            return
        }

        phase = .checking
        BankSyncService.logger.info("Autorisierung: Code-Tausch für \(institution.name, privacy: .public) gestartet")
        do {
            let sessionID = try await provider.authorizeSession(code: code)
            pendingConnectionID = sessionID
            BankSyncService.logger.info("Autorisierung: Session …\(sessionID.suffix(4), privacy: .public) angelegt")

            let service = BankSyncService(dependencies: dependencies, provider: provider)
            let connection = try await service.connect(
                institution: institution,
                providerConnectionID: sessionID,
                linkedAccountIDs: [],
                providerRaw: .enablebanking
            )
            let requestedStart = historyRange.startDate(now: Date())
            let result = try await service.sync(connection: connection, historyStart: requestedStart)
            historyNotice = Self.historyNotice(requestedStart: requestedStart, earliestDelivered: result.earliestBookingDate)
            await removeSupersededConnections(keeping: connection)
            consentValidUntil = try? await dependencies.connectionRepository.connections()
                .first { $0.id == connection.id }?.consentExpiresAt
            renewalPurpose = nil
            phase = .success(accountsCreated: result.accountsSynced)
            dependencies.changeTracker.markChanged()
            await loadConnections()
        } catch {
            // Rule 17/§38: Die konkrete Ursache sichtbar machen. Enable
            // Banking meldet im Fehler-Body z. B. abgelaufene Codes.
            BankSyncService.logger.error("Autorisierung fehlgeschlagen: \(BankSyncService.describe(error), privacy: .public)")
            phase = .failed(Self.authorizationFailureMessage(error))
        }
    }

    static func authorizationFailureMessage(_ error: Error) -> String {
        if case BankProviderError.requestFailed(_, let status, let body) = error {
            var text = String(localized: "Enable Banking hat die Anfrage abgelehnt (HTTP \(status)).")
            if let body, !body.isEmpty {
                text += "\n" + String(localized: "API-Antwort: \(body)")
            }
            text += "\n" + String(localized: "Der Code ist einmalig nutzbar. Bitte einen frischen Code erzeugen (Bank-Login erneut durchlaufen).")
            return text
        }
        return String(localized: "Die Sitzung konnte nicht autorisiert werden (\(String(describing: error))). Der Code ist einmalig nutzbar. Bitte einen frischen Code erzeugen.")
    }

    static func firstURL(in text: String) -> URLComponents? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector?.matches(in: text, range: range) ?? []
        for match in matches.reversed() {
            if let url = match.url { return URLComponents(url: url, resolvingAgainstBaseURL: false) }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URLComponents(string: trimmed)
    }

    // MARK: - GoCardless: Status-Check-Flow

    func checkAuthorizationAndFinish() async {
        guard kind == .gocardless,
              let connectionID = pendingConnectionID,
              let institution = selectedInstitution else { return }

        phase = .checking
        do {
            let service = BankSyncService(dependencies: dependencies, provider: provider)
            let connection = try await service.connect(
                institution: institution,
                providerConnectionID: connectionID,
                linkedAccountIDs: []
            )

            let state = try await provider.connectionStatus(connectionID: connectionID)

            guard state.authorization == .ready else {
                phase = .waitingForAuthorization(url: nil, institutionName: institution.name)
                return
            }

            let result = try await service.sync(connection: connection)
            phase = .success(accountsCreated: result.accountsSynced)
            dependencies.changeTracker.markChanged()
        } catch {
            phase = .failed(String(localized: "Die Verbindung konnte nicht geprüft werden."))
        }
    }

    /// Zurück zur Bankauswahl, ohne die Freigabe abzuschließen. Die bei
    /// Enable Banking angelegte Anfrage verfällt von selbst.
    func chooseAnotherBank() {
        selectedInstitution = nil
        pendingConnectionID = nil
        pendingAuthorizationURL = nil
        redirectURLInput = "https://enablebanking.com/redirect"
        phase = .institutions
    }

    func retryAfterFailure() {
        phase = selectedInstitution != nil ? .institutions : .credentials
    }

    // MARK: - Consent-Health: Laden, Einstufen, Erneuern

    /// Lädt bestehende Connections (read-only) für Banner + Pro-Connection-Zeile.
    func loadConnections() async {
        guard !isLoadingConnections else { return }
        isLoadingConnections = true
        connectionsErrorMessage = nil
        defer { isLoadingConnections = false }
        do {
            let fetched = try await dependencies.connectionRepository.connections()
            connections = fetched.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            connectionsErrorMessage = String(localized: "Die Bankverbindungen konnten nicht geladen werden.")
        }
    }

    func health(for connection: Connection, now: Date = Date()) -> ConnectionHealth {
        healthEvaluator.health(for: connection, now: now)
    }

    /// Banner-Quelle (T-10d + abgelaufen, ohne blockierte).
    var attentionConnections: [Connection] {
        healthEvaluator.connectionsNeedingAttention(in: connections)
    }

    var showsConsentBanner: Bool { !attentionConnections.isEmpty }

    var consentBannerMessage: String? {
        healthEvaluator.bannerMessage(for: attentionConnections)
    }

    func syncIssue(for connection: Connection) -> SyncFailureKind? {
        syncIssues[connection.id]
    }

    func syncIssueMessage(for connection: Connection) -> String? {
        syncIssueMessages[connection.id]
    }

    func statusLabel(for connection: Connection, now: Date = Date()) -> String {
        if let expires = connection.consentExpiresAt, expires < now {
            return String(localized: "Zustimmung abgelaufen")
        }
        return switch connection.status {
        case .active: String(localized: "Verbunden")
        case .pendingAuthorization: String(localized: "Autorisierung offen")
        case .expired: String(localized: "Abgelaufen")
        case .revoked: String(localized: "Zugriff widerrufen")
        case .disconnected: String(localized: "Getrennt")
        }
    }

    func needsReconnect(_ connection: Connection, now: Date = Date()) -> Bool {
        switch health(for: connection, now: now) {
        case .expired, .blocked: true
        case .noConsentInfo, .healthy, .expiring: connection.status != .active
        }
    }

    /// Erneuter Sync einer bestehenden Connection (read-only: kein neuer
    /// Zahlungs-Flow). Fehler werden 3-wege-klassifiziert statt still
    /// verworfen.
    func refreshConnection(_ connection: Connection) async {
        guard syncingConnectionID == nil else { return }
        syncingConnectionID = connection.id
        syncIssues[connection.id] = nil
        syncIssueMessages[connection.id] = nil
        lastSyncNotice = nil
        defer { syncingConnectionID = nil }
        do {
            let routed = dependencies.bankProviderFactory.makeBankDataProvider(for: connection)
            let service = BankSyncService(dependencies: dependencies, provider: routed)
            let result = try await service.sync(connection: connection)
            dependencies.changeTracker.markChanged()
            await loadConnections()
            lastSyncNotice = String(localized: "Sync fertig: \(result.importedCount) neu, \(result.updatedCount) aktualisiert.")
        } catch {
            let kind = healthEvaluator.classify(syncError: error, connection: connection)
            syncIssues[connection.id] = kind
            syncIssueMessages[connection.id] = Self.syncDisplayMessage(kind: kind, error: error)
        }
    }

    /// Nutzer-facing 3-Wege-Texte (keine Secrets, kein Provider-Jargon).
    static func syncDisplayMessage(kind: SyncFailureKind, error: Error) -> String {
        switch kind {
        case .transientRetry:
            if case BankProviderError.requestFailed(_, let status, _) = error {
                return String(localized: "Sync kurz gestört (HTTP \(status)). Bitte erneut versuchen. Die Verbindung bleibt bestehen.")
            }
            return String(localized: "Sync kurz gestört. Bitte erneut versuchen. Die Verbindung bleibt bestehen.")
        case .reauthRequired:
            return String(localized: "Zugang abgelaufen. Bitte jetzt erneuern (erneute Freigabe bei der Bank nötig).")
        case .blocked:
            return String(localized: "Zugriff blockiert oder widerrufen. Bitte neu verbinden. Bereits importierte Daten bleiben erhalten.")
        }
    }
}
