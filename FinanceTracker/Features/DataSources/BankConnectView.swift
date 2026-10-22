import SwiftUI
import UniformTypeIdentifiers

/// Bank-Verbindungs-Flow, provider-fähig: Enable Banking (eigene Production-
/// Konten oder Sandbox; GoCardless-Sign-ups sind eingefroren) und GoCardless
/// (Bestands-Keys). Salt Edge später über denselben Provider-Slot.
struct BankConnectView: View {
    let dependencies: AppDependencies
    let onDone: () -> Void
    /// Direkt mit der neuen Freigabe für diese Verbindung starten.
    var renewal: (connection: Connection, purpose: BankConnectModel.RenewalPurpose)?

    @State private var model: BankConnectModel
    @State private var revealsPrivateKey = false
    @State private var confirmsCredentialDeletion = false
    @State private var importsKeyFile = false
    @State private var copiedValue: String?
    @State private var connectionPendingDisconnect: Connection?
    @FocusState private var searchFocused: Bool

    init(
        dependencies: AppDependencies,
        renewal: (connection: Connection, purpose: BankConnectModel.RenewalPurpose)? = nil,
        onDone: @escaping () -> Void
    ) {
        self.dependencies = dependencies
        self.renewal = renewal
        self.onDone = onDone
        // Nur künstliche Empty-/Storage-Error-Zustände verwenden leere
        // Credentials. Normale UI-/Visual-QA-Läufe prüfen bewusst die lokal
        // konfigurierte Enable-Banking-Mock-Verbindung.
        if AppLaunchEnvironment.live.requiresIsolatedStore {
            _model = State(initialValue: BankConnectModel(
                dependencies: dependencies,
                credentialStore: InMemoryGoCardlessCredentialStore(),
                enableBankingCredentialStore: InMemoryEnableBankingCredentialStore(
                    applicationID: nil,
                    privateKeyPEM: nil
                )
            ))
        } else {
            _model = State(initialValue: BankConnectModel(dependencies: dependencies))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let header = headerText {
                PageHeader(header.title, subtitle: header.subtitle)
                    .padding(.horizontal, AppSpacing.xl)
                    .padding(.top, AppSpacing.m)
                    .padding(.bottom, AppSpacing.xs)
            }
            Group {
                switch model.phase {
            case .credentials:
                if model.isLoadingStoredCredentials {
                    VStack(spacing: AppSpacing.l) {
                        ProgressView()
                        Text("Zugangsdaten werden geladen …")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Fragt macOS nach dem Schlüsselbund, wähle „Immer erlauben“.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    credentialsForm
                }
            case .connecting:
                VStack(spacing: AppSpacing.l) {
                    ProgressView()
                    Text("Verbindung wird vorbereitet…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .checking:
                VStack(spacing: AppSpacing.l) {
                    ProgressView()
                    Text("Verbindung wird geprüft…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .institutions:
                institutionsList
            case .waitingForAuthorization(let url, let institutionName):
                waitingForAuthorization(url: url, institutionName: institutionName)
            case .codeExchange(let authorizationID, let institutionName, let authURL):
                codeExchange(authorizationID: authorizationID, institutionName: institutionName, authURL: authURL)
            case .success(let accountsCreated):
                successSummary(accountsCreated: accountsCreated)
            case .failed(let message):
                failedView(message)
            }
            }
        }
        .onAppear {
            if let renewal {
                // Gleich zur Freigabe; die Zugangsdaten liegen bereits vor.
                Task {
                    await model.loadConnections()
                    switch renewal.purpose {
                    case .reauthorize: await model.reauthorize(renewal.connection)
                    case .olderTransactions: await model.requestOlderTransactions(for: renewal.connection)
                    }
                }
            } else {
                Task { await model.loadStoredCredentialsIfNeeded() }
                Task { await model.loadConnections() }
            }
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .credentials {
                revealsPrivateKey = false
            }
        }
        .alert("\(model.kind.displayName)-Zugang für alle Banken entfernen?", isPresented: $confirmsCredentialDeletion) {
            Button("Für alle Banken entfernen", role: .destructive) {
                revealsPrivateKey = false
                model.deleteCredentials()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(credentialDeletionMessage)
        }
        .alert(
            "Verbindung trennen?",
            isPresented: Binding(
                get: { connectionPendingDisconnect != nil },
                set: { if !$0 { connectionPendingDisconnect = nil } }
            ),
            presenting: connectionPendingDisconnect
        ) { connection in
            Button("\(connection.displayName) trennen", role: .destructive) {
                connectionPendingDisconnect = nil
                Task { await model.disconnect(connection) }
            }
            Button("Abbrechen", role: .cancel) { connectionPendingDisconnect = nil }
        } message: { connection in
            Text("Nur \(connection.displayName) wird getrennt. Konten und Buchungen bleiben erhalten, werden aber nicht mehr abgerufen. Andere Banken sind nicht betroffen.")
        }
    }

    private var credentialDeletionMessage: String {
        let banks = model.banksUsingCredentials
        let affected = banks.isEmpty
            ? String(localized: "Danach kann die App keine Umsätze mehr abrufen")
            : String(localized: "Danach kann die App bei keiner Bank mehr Umsätze abrufen (\(ListFormatter.localizedString(byJoining: banks)))")
        return String(localized: "Der Schlüssel deiner \(model.kind.displayName)-Anwendung wird von diesem Mac entfernt. \(affected), bis du ihn erneut lädst. Konten und Buchungen bleiben erhalten.\n\nNur eine Bank entfernen? Dann bei der Bank „Trennen“ wählen.")
    }

    // MARK: - Consent-Health (P1, PSD2 read-only)

    /// Überschrift je Schritt; die Erfolgsseite trägt ihre eigene.
    private var headerText: (title: String, subtitle: String)? {
        switch model.phase {
        case .credentials where model.isLoadingStoredCredentials:
            (String(localized: "Bankkonto verbinden"), String(localized: "Die App liest nur. Zahlungen sind nicht möglich."))
        case .credentials:
            (String(localized: "Bankkonto verbinden"), String(localized: "Einmalig: deine eigene Enable-Banking-Anwendung einrichten."))
        case .institutions, .connecting, .checking, .failed:
            (String(localized: "Bankkonto verbinden"), String(localized: "Wähle deine Bank. Die App liest nur. Zahlungen sind nicht möglich."))
        case .codeExchange(_, let institutionName, _), .waitingForAuthorization(_, let institutionName):
            model.renewalPurpose == .reauthorize
                ? (String(localized: "\(institutionName) neu autorisieren"), String(localized: "Verlängert den Lesezugriff auf die volle Dauer, die deine Bank erlaubt."))
                : (String(localized: "\(institutionName) freigeben"), String(localized: "Melde dich bei deiner Bank an und gib den Lesezugriff frei."))
        case .success:
            nil
        }
    }

    /// Banner (T-10d) + Pro-Connection-Zeile („Zuletzt synchronisiert /
    /// läuft ab am / Jetzt erneuern“) + 3-Wege-Fehler. Loading/Error/Empty
    /// werden explizit behandelt; keine Business-Logik in der View.
    @ViewBuilder
    private var consentHealthSection: some View {
        if model.isLoadingConnections {
            Section {
                HStack(spacing: AppSpacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Bankverbindungen werden geladen …")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Bankverbindungen werden geladen")
            }
        } else if let error = model.connectionsErrorMessage {
            Section {
                HStack(spacing: AppSpacing.s) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppPalette.warning)
                    Spacer()
                    Button("Erneut versuchen") {
                        Task { await model.loadConnections() }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Bankverbindungen erneut laden")
                }
            }
        } else if !model.connections.isEmpty {
            Section {
                if model.showsConsentBanner, let banner = model.consentBannerMessage {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Freigabe läuft bald ab").fontWeight(.semibold)
                            Text(banner).font(.caption)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(AppPalette.warning)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("consent-expiry-banner")
                }
                ForEach(model.connections) { connection in
                    consentRow(for: connection)
                }
            } header: {
                Text("Deine Bankverbindungen")
            } footer: {
                if let notice = model.lastSyncNotice {
                    Text(notice)
                        .accessibilityLabel("Abruf: \(notice)")
                }
            }
        }
    }

    private func consentRow(for connection: Connection) -> some View {
        let needsReconnect = model.needsReconnect(connection)
        let issue = model.syncIssue(for: connection)
        let issueMessage = model.syncIssueMessage(for: connection)
        let lastSync = connection.lastSuccessfulSyncAt
            .map { String(localized: "Abgerufen \($0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated).locale(.current)))") }
            ?? String(localized: "Noch nie abgerufen")
        let expiry = connection.consentExpiresAt
            .map { String(localized: "Freigabe bis \($0.formatted(date: .abbreviated, time: .omitted))") }
            ?? String(localized: "Freigabe ohne Ablaufdatum")

        return VStack(alignment: .leading, spacing: AppSpacing.s) {
            HStack(alignment: .center, spacing: AppSpacing.m) {
                IconTile(systemName: "building.columns.fill", color: AppPalette.information, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text("\(lastSync) · \(expiry)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: AppSpacing.s)
                StatusBadge(
                    title: model.statusLabel(for: connection),
                    tone: needsReconnect ? .warning : .positive
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(connection.displayName), \(model.statusLabel(for: connection)), \(lastSync), \(expiry)")

            if let issue, let issueMessage {
                Label(issueMessage, systemImage: issue == .blocked ? "xmark.octagon.fill" : "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(issue == .blocked ? AppPalette.critical : AppPalette.warning)
                    .accessibilityLabel("Hinweis für \(connection.displayName): \(issueMessage)")
            }

            HStack(spacing: AppSpacing.s) {
                Spacer(minLength: 0)
                if model.syncingConnectionID == connection.id {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Umsätze von \(connection.displayName) werden abgerufen")
                } else {
                    if connection.provider == .enablebanking {
                        Button {
                            Task { await model.requestOlderTransactions(for: connection) }
                        } label: {
                            Label("Ältere Umsätze …", systemImage: "clock.arrow.circlepath")
                        }
                        .controlSize(.small)
                        .help("Meldet dich erneut bei der Bank an und fragt einen längeren Zeitraum ab.")
                        .accessibilityLabel("Ältere Umsätze von \(connection.displayName) anfragen")
                        .accessibilityIdentifier("consent-older-\(connection.id.uuidString)")
                    }
                    Button(role: .destructive) {
                        connectionPendingDisconnect = connection
                    } label: {
                        Label("Trennen …", systemImage: "link.badge.minus")
                    }
                    .controlSize(.small)
                    .help("Nur diese Bank trennen. Konten und Buchungen bleiben erhalten.")
                    .accessibilityLabel("\(connection.displayName) trennen")
                    Button {
                        Task { await model.refreshConnection(connection) }
                    } label: {
                        Label("Jetzt abrufen", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Umsätze von \(connection.displayName) jetzt abrufen")
                    .accessibilityIdentifier("consent-renew-\(connection.id.uuidString)")
                    .applyReconnectStyle(needsReconnect)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Credentials

    @ViewBuilder
    private var credentialsForm: some View {
        switch model.kind {
        case .enablebanking: enableBankingCredentialsForm
        case .gocardless: goCardlessCredentialsForm
        }
    }

    /// Geführte Einrichtung: Anwendung und Konten entstehen im Control Panel
    /// von Enable Banking, die App führt durch die Schritte, lädt den
    /// Schlüssel und prüft danach die Anwendung (`GET /application`).
    private var enableBankingCredentialsForm: some View {
        Form {
            Section {
                setupStep(
                    1,
                    "Anwendung anlegen",
                    "Melde dich bei Enable Banking an und lege eine neue Anwendung an. Wähle als Umgebung Production. Eine Sandbox-Anwendung liefert nur Testdaten."
                )
                copyRow("Als Redirect-URL eintragen", BankConnectModel.setupRedirectURL)
                if let privacy = BankConnectModel.privacyPolicyURL, let terms = BankConnectModel.termsURL {
                    copyRow("Als Privacy-URL eintragen", privacy)
                    copyRow("Als Terms-URL eintragen", terms)
                } else {
                    Text("Für Privacy- und Terms-URL verlangt Enable Banking je einen Link: Verlinke die Seiten PRIVACY und TERMS aus dem Repository der App. Als Datenschutz-E-Mail trägst du deine eigene Adresse ein.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Nach „Register“ lädt dein Browser den privaten Schlüssel als .pem-Datei herunter. Ihr Dateiname ist die Application ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(destination: BankConnectModel.controlPanelURL) {
                    Label("Control Panel öffnen", systemImage: "arrow.up.right.square")
                }
            }

            Section {
                setupStep(
                    2,
                    "Eigene Konten verknüpfen",
                    "Klicke bei der neuen Anwendung auf „Activate by linking accounts“ und gib bei deiner Bank alle Konten frei, die die App sehen soll. Ohne Vertrag mit Enable Banking sind nur diese verknüpften Konten abrufbar."
                )
            }

            Section {
                setupStep(3, "Schlüssel laden", "Wähle die heruntergeladene .pem-Datei. Sie bleibt im Schlüsselbund dieses Macs.")
                HStack(spacing: AppSpacing.s) {
                    Button {
                        importsKeyFile = true
                    } label: {
                        Label("Schlüsseldatei auswählen …", systemImage: "key")
                    }
                    if let message = model.keyFileMessage {
                        Label(message, systemImage: model.keyFileLoaded ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(model.keyFileLoaded ? AppPalette.positive : AppPalette.warning)
                    }
                }
                TextField("Application ID", text: $model.applicationIDInput)
                    .textContentType(.username)
                DisclosureGroup("Schlüssel stattdessen einfügen") {
                    VStack(alignment: .leading, spacing: AppSpacing.s) {
                        if revealsPrivateKey {
                            TextEditor(text: $model.privateKeyInput)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 120)
                                .accessibilityLabel("Privater Schlüssel (PEM), sichtbar")
                        } else {
                            SecureField("Privater Schlüssel (PEM)", text: $model.privateKeyInput)
                                .font(.system(.caption, design: .monospaced))
                                .textContentType(.password)
                                .accessibilityLabel("Privater Schlüssel (PEM), verdeckt")
                        }
                        Button {
                            revealsPrivateKey.toggle()
                        } label: {
                            Label(
                                revealsPrivateKey ? String(localized: "Privaten Schlüssel verbergen") : String(localized: "Privaten Schlüssel anzeigen"),
                                systemImage: revealsPrivateKey ? "eye.slash" : "eye"
                            )
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, AppSpacing.xs)
                }
            }

            Section {
                setupStep(
                    4,
                    "Speichern und prüfen",
                    "Die App fragt bei Enable Banking nach, ob die Anwendung auf Production steht, aktiv ist und die Redirect-URL stimmt. Danach wählst du deine Bank und gibst sie im Browser frei. Deine Bank-Login-Daten gehören nie in diese App."
                )
                Button {
                    Task { await model.saveCredentialsAndContinue() }
                } label: {
                    Label("Speichern & prüfen", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSaveEnableBankingCredentials)
            }

            Section {
                Text("Nur ausprobieren? Eine Sandbox-Anwendung mit der Testbank „Mock ASPSP“ genügt, ganz ohne echte Konten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    confirmsCredentialDeletion = true
                } label: {
                    Label(credentialDeletionTitle, systemImage: "key.slash")
                }
            }
        }
        .financeFormStyle()
        .fileImporter(
            isPresented: $importsKeyFile,
            allowedContentTypes: Self.keyFileTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await model.importPrivateKeyFile(at: url) }
            case .failure:
                model.keyFileSelectionFailed()
            }
        }
    }

    private static let keyFileTypes: [UTType] = {
        var types: [UTType] = [.plainText, .data]
        if let pem = UTType(filenameExtension: "pem") { types.insert(pem, at: 0) }
        return types
    }()

    private func setupStep(_ number: Int, _ title: LocalizedStringResource, _ detail: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.m) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(AppPalette.brand))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Schritt \(number): \(String(localized: title)). \(String(localized: detail))")
    }

    /// Wert zum Eintragen im Control Panel, mit Kopieren-Knopf.
    private func copyRow(_ label: LocalizedStringResource, _ value: String) -> some View {
        HStack(spacing: AppSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: AppSpacing.s)
            Button {
                copyToPasteboard(value)
                copiedValue = value
            } label: {
                Label(copiedValue == value ? String(localized: "Kopiert") : String(localized: "Kopieren"), systemImage: copiedValue == value ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .accessibilityLabel("\(String(localized: label)): kopieren")
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Vorabprüfung der Anwendung (Production-Banklauf): Was `GET /application`
    /// über Umgebung, Aktivierung und Redirect-URL sagt, bevor eine Bank
    /// angefasst wird.
    @ViewBuilder
    private var applicationStatus: some View {
        if model.isCheckingApplication {
            HStack(spacing: AppSpacing.s) {
                ProgressView().controlSize(.small)
                Text("Anwendung wird geprüft…")
            }
            .accessibilityLabel("Anwendung wird geprüft")
        } else if let info = model.applicationInfo {
            let ready = info.isActive && model.applicationWarnings.isEmpty
            HStack(spacing: AppSpacing.s) {
                Image(systemName: ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ready ? AppPalette.positive : AppPalette.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).fontWeight(.medium)
                    Text("\(BankConnectModel.environmentLabel(info.environment)) · \(info.isActive ? String(localized: "aktiv") : String(localized: "inaktiv")) · \(info.countries.isEmpty ? String(localized: "Länder unbekannt") : info.countries.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Erneut prüfen") { Task { await model.checkApplication() } }
                    .controlSize(.small)
                    .accessibilityLabel("Anwendung erneut prüfen")
            }
            .accessibilityElement(children: .combine)
            ForEach(model.applicationWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppPalette.warning)
            }
            if ready {
                Label("Bereit für echte Konten.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(AppPalette.positive)
            }
        } else if let message = model.applicationCheckMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(AppPalette.warning)
            Button("Erneut prüfen") { Task { await model.checkApplication() } }
                .controlSize(.small)
                .accessibilityLabel("Anwendung erneut prüfen")
        } else {
            Button("Anwendung prüfen") { Task { await model.checkApplication() } }
                .controlSize(.small)
                .accessibilityLabel("Anwendung über die API prüfen")
        }
    }

    private var goCardlessCredentialsForm: some View {
        Form {
            Section {
                Label("Bestandszugang (Sign-ups pausiert)", systemImage: "wrench.and.screwdriver.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppPalette.warning)

                TextField("Secret ID", text: $model.secretIDInput)
                    .textContentType(.username)
                SecureField("Secret Key", text: $model.secretKeyInput)

                DisclosureGroup("Hinweis zu GoCardless") {
                    VStack(alignment: .leading, spacing: AppSpacing.s) {
                        Text("Neue Zugänge sind pausiert. Dieser Weg funktioniert nur mit einem bestehenden Bank-Account-Data-Konto.")
                        Link(
                            "Gespeicherte User Secrets öffnen",
                            destination: URL(string: "https://bankaccountdata.gocardless.com/user-secrets/")!
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, AppSpacing.xs)
                }
            } header: {
                Text("GoCardless Zugangsdaten")
            }

            Button {
                Task { await model.saveCredentialsAndContinue() }
            } label: {
                Label("Speichern & Institute laden", systemImage: "key.fill")
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                confirmsCredentialDeletion = true
            } label: {
                Label(credentialDeletionTitle, systemImage: "key.slash")
            }
        }
        .financeFormStyle()
    }

    // MARK: - Institutions

    private var institutionsList: some View {
        Form {
            consentHealthSection

            if model.kind == .gocardless {
                Section {
                    Button {
                        Task { await model.startSandboxConnection() }
                    } label: {
                        HStack(spacing: AppSpacing.s) {
                            Label("Sandbox Finance", systemImage: "testtube.2")
                            Spacer()
                            Text("Testdaten")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(AppPalette.warning.opacity(0.15)))
                                .foregroundStyle(AppPalette.warning)
                        }
                    }
                    .accessibilityLabel("Sandbox Finance mit Testdaten verbinden")
                } header: {
                    Text("Sandbox")
                } footer: {
                    Text("Mock-Bank von GoCardless: im Login einfach beliebige Werte eingeben. Kein echtes Bankkonto, keine PSD2-Authentifizierung.")
                }
            }

            // Probleme mit der Anwendung gehören nach oben, sonst scheitert
            // der Bank-Login erst im Browser.
            if model.kind == .enablebanking, applicationNeedsAttention {
                Section {
                    applicationStatus
                } header: {
                    Text("Anwendung prüfen")
                }
            }

            Section {
                bankSearchField
                institutionRows
            } header: {
                model.isSearching ? Text("Suchergebnisse") : Text("Bank hinzufügen")
            } footer: {
                institutionFooter
            }

            Section {
                DisclosureGroup("Erweitert") {
                    VStack(alignment: .leading, spacing: AppSpacing.m) {
                        if model.kind == .enablebanking, !applicationNeedsAttention {
                            applicationStatus
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirmsCredentialDeletion = true
                        } label: {
                            Label(credentialDeletionTitle, systemImage: "key.slash")
                        }
                        Text("Gilt für alle Banken. Um nur eine Bank zu entfernen, nutze oben bei der Bank „Trennen“.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, AppSpacing.xs)
                }
            }
        }
        .financeFormStyle()
    }

    private var applicationNeedsAttention: Bool {
        model.applicationCheckMessage != nil || !model.applicationWarnings.isEmpty
            || (model.applicationInfo.map { !$0.isActive } ?? false)
    }

    private var credentialDeletionTitle: String {
        model.kind == .enablebanking ? String(localized: "Enable-Banking-Schlüssel entfernen …") : String(localized: "GoCardless-Zugangsdaten entfernen …")
    }

    /// Suchfeld mit Länderwahl, sichtbar im Dialog, nicht in der Toolbar.
    private var bankSearchField: some View {
        HStack(spacing: AppSpacing.s) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Bank suchen", text: $model.searchText, prompt: Text("Bank suchen, z. B. DKB"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .focused($searchFocused)
                    .accessibilityLabel("Bank suchen")
                    .accessibilityIdentifier("bank-search")
                if model.isSearching {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Suche leeren")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(AppPalette.sunken)
            )

            Menu {
                ForEach(model.availableCountries, id: \.self) { code in
                    Button {
                        Task { await model.selectCountry(code) }
                    } label: {
                        if code == model.country {
                            Label(BankConnectModel.countryName(code), systemImage: "checkmark")
                        } else {
                            Text(BankConnectModel.countryName(code))
                        }
                    }
                }
            } label: {
                Text(BankConnectModel.countryName(model.country))
            }
            .menuStyle(.button)
            .fixedSize()
            .accessibilityLabel("Land: \(BankConnectModel.countryName(model.country))")
            .accessibilityIdentifier("bank-country")
        }
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private var institutionRows: some View {
        if model.isLoadingInstitutions {
            HStack(spacing: AppSpacing.s) {
                ProgressView().controlSize(.small)
                Text("Banken in \(BankConnectModel.countryName(model.country)) werden geladen …")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, AppSpacing.xs)
        } else if model.isSearching {
            let result = model.searchResult
            if result.matches.isEmpty {
                Text("Keine Bank zu „\(model.searchText)“ in \(BankConnectModel.countryName(model.country)). Anders schreiben oder ein anderes Land wählen.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(result.matches) { institutionRow($0) }
            }
        } else {
            let popular = model.popularInstitutions
            let groups = model.groupShortcuts
            if !groups.isEmpty {
                HStack(spacing: AppSpacing.s) {
                    Text(groupShortcutQuestion(groups))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    ForEach(groups, id: \.self) { group in
                        Button(group) {
                            model.searchText = group + " "
                            searchFocused = true
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Nach \(group) suchen")
                    }
                }
            }
            if popular.isEmpty {
                Text("Gib oben den Namen deiner Bank ein.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(popular) { institutionRow($0) }
            }
        }
    }

    @ViewBuilder
    private var institutionFooter: some View {
        if model.isLoadingInstitutions {
            EmptyView()
        } else if model.isSearching {
            let hidden = model.searchResult.hiddenCount
            if hidden > 0 {
                Text("\(hidden) weitere Treffer. Genauer suchen, z. B. mit dem Ort.")
            } else {
                Text(connectFooter)
            }
        } else if !model.institutions.isEmpty {
            Text("Beliebte Banken. Alle \(model.institutions.count.formatted()) Banken in \(BankConnectModel.countryName(model.country)) findest du über die Suche, auch deine Sparkasse oder Volksbank.")
        }
    }

    private var connectFooter: String {
        model.kind == .enablebanking
            ? String(localized: "Nach der Auswahl meldest du dich bei deiner Bank an und gibst den Lesezugriff frei.")
            : String(localized: "Nach der Auswahl öffnet sich der Bank-Login. Danach hier bestätigen.")
    }

    /// „Sparkasse, Volksbank oder PSD Bank?“: Gruppen als Frage, „oder“ vor
    /// dem letzten Eintrag.
    private func groupShortcutQuestion(_ groups: [String]) -> String {
        guard let last = groups.last, groups.count > 1 else {
            return "\(groups.first ?? "")?"
        }
        return String(localized: "\(groups.dropLast().joined(separator: ", ")) oder \(last)?")
    }

    private func institutionRow(_ institution: BankInstitution) -> some View {
        let connected = model.isConnected(institution)
        return Button {
            Task { await model.startConnection(for: institution) }
        } label: {
            HStack(spacing: AppSpacing.m) {
                BankLogo(name: institution.name, url: institution.logoURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(institution.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if connected {
                        Text("Bereits verbunden. Erneut auswählen gibt neu frei")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.kind == .gocardless, let bic = institution.bic {
                        Text(bic).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(connected ? String(localized: "\(institution.name), bereits verbunden") : String(localized: "\(institution.name) verbinden"))
    }

    // MARK: - Waiting (GoCardless)

    private func waitingForAuthorization(url: URL?, institutionName: String) -> some View {
        VStack(spacing: AppSpacing.l) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
            Text("\(institutionName) verbinden")
                .font(.headline)

            if url != nil, model.isWaitingForSandbox {
                Label("Mock-Bank: im Login einfach beliebige Werte eingeben.", systemImage: "testtube.2")
                    .font(.callout)
                    .foregroundStyle(AppPalette.warning)
            }

            if let url {
                Button("Bank-Login öffnen") {
                    openURL(url)
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                Task { await model.checkAuthorizationAndFinish() }
            } label: {
                Label("Verbindung geprüft, weiter", systemImage: "checkmark.seal")
            }


        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppSpacing.xl)
    }

    // MARK: - Code Exchange (Enable Banking)

    private var stepOneHint: LocalizedStringResource {
        switch model.renewalPurpose {
        case .olderTransactions:
            "Ältere Umsätze gibt es meist nur direkt nach einer frischen Anmeldung. Vorhandene Buchungen werden nicht doppelt angelegt."
        case .reauthorize:
            "Zum Verlängern reicht „Standard der Bank“. Ein längerer Zeitraum holt zusätzlich ältere Umsätze nach, ohne Doppelte."
        case nil:
            "Mehr als etwa 90 Tage liefern nicht alle Banken. Die App zeigt danach, ab wann Umsätze kamen."
        }
    }

    private func codeExchange(authorizationID: String, institutionName: String, authURL: URL?) -> some View {
        Form {
            Section {
                setupStep(
                    1,
                    "Zeitraum wählen",
                    stepOneHint
                )
                Picker("Umsätze laden ab", selection: $model.historyRange) {
                    ForEach(BankConnectModel.HistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .accessibilityIdentifier("bank-history-range")
            }

            Section {
                setupStep(2, "Bei \(institutionName) anmelden", "Im Browser öffnet sich deine Bank. Melde dich an und gib die Konten frei.")
                if let authURL {
                    Button {
                        openURL(authURL)
                    } label: {
                        Label("Bank-Login öffnen", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section {
                setupStep(
                    3,
                    "Adresse einfügen",
                    "Danach landest du auf einer Seite von Enable Banking, die evtl. einen Fehler zeigt. Das ist normal. Kopiere die komplette Adresse aus der Adresszeile hierher."
                )
                TextField("Adresse mit Code", text: Binding(
                    get: { model.redirectURLInput == "https://enablebanking.com/redirect" ? "" : model.redirectURLInput },
                    set: { model.redirectURLInput = $0 }
                ), prompt: Text(verbatim: "https://enablebanking.com/redirect?code=…"))
                .labelsHidden()
                .font(.system(.callout, design: .monospaced))
                .accessibilityLabel("Adresse mit Code einfügen")

                Button {
                    Task { await model.finishWithRedirectURL(model.redirectURLInput) }
                } label: {
                    Label("Verbinden", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.redirectURLInput.trimmingCharacters(in: .whitespaces).isEmpty
                        || model.redirectURLInput == "https://enablebanking.com/redirect"
                )
            }

            if model.renewalPurpose == nil {
                Section {
                    Button {
                        model.chooseAnotherBank()
                    } label: {
                        Label("Andere Bank wählen", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Zurück zur Bankauswahl")
                }
            }
        }
        .financeFormStyle()
    }

    // MARK: - Result

    private func successSummary(accountsCreated: Int) -> some View {
        VStack(spacing: AppSpacing.l) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(AppPalette.positive)
                .accessibilityHidden(true)
            VStack(spacing: AppSpacing.s) {
                Text("Bank verbunden")
                    .font(.title2.weight(.semibold))
                (accountsCreated == 1 ? Text("1 Konto abgerufen.") : Text("\(accountsCreated) Konten abgerufen."))
                    .foregroundStyle(.secondary)
            }
            if let validUntil = model.consentValidUntil {
                Label("Lesezugriff gültig bis \(AppDateFormatter.day(validUntil))", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let notice = model.historyNotice {
                Label(notice, systemImage: "calendar")
                    .font(.callout)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: 380)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .fill(AppPalette.sunken)
                    )
            }
            Button("Fertig", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.canvas)
        .accessibilityElement(children: .contain)
    }

    private func failedView(_ message: String) -> some View {
        ErrorStateView(message: message) {
            model.retryAfterFailure()
        }
    }

    private func openURL(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

extension View {
    /// Ternäre ButtonStyles typisieren nicht (zwei verschiedene
    /// ButtonStyle-Typen), daher zwei getrennte Modifier-Pfade.
    @ViewBuilder
    func applyReconnectStyle(_ prominent: Bool) -> some View {
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// Logo der Bank, solange es lädt oder fehlt ein Kachel mit Initialen.
private struct BankLogo: View {
    let name: String
    let url: URL?
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(AppPalette.sunken)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(size * 0.12)
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initials: some View {
        Text(Self.initials(of: name))
            .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
    }

    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first).map(String.init)
        return letters.joined().uppercased()
    }
}
