import SwiftUI

struct AccountsView: View {
    @State private var model: AccountsModel
    @State private var activeSheet: AccountSheet?
    @State private var syncingConnectionID: UUID?
    @State private var syncMessage: String?
    @State private var connectionPendingDisconnect: Connection?
    @State private var accountPendingDeletion: AccountSummary?
    @Environment(PrivacyPresentationState.self) private var privacyState
    /// WP24: Ausstehende Palette-Route (Konto-Detail).
    var pendingRoute: Binding<PaletteRoute?>

    private enum AccountSheet: Identifiable {
        case addDataSource
        case account(Account)
        /// Konto manuell anlegen (nil) oder bearbeiten.
        case editor(Account?)
        /// Bestehende Bankverbindung neu freigeben: verlängern oder ältere
        /// Umsätze nachladen.
        case renewal(Connection, BankConnectModel.RenewalPurpose)

        var id: String {
            switch self {
            case .addDataSource: "add-data-source"
            case .account(let account): "account-\(account.id.uuidString)"
            case .editor(let account): "editor-\(account?.id.uuidString ?? "new")"
            case .renewal(let connection, let purpose): "renewal-\(purpose)-\(connection.id.uuidString)"
            }
        }
    }

    init(dependencies: AppDependencies, pendingRoute: Binding<PaletteRoute?>) {
        _model = State(initialValue: AccountsModel(dependencies: dependencies))
        self.pendingRoute = pendingRoute
    }

    private var addManualAccountButton: some View {
        Button {
            activeSheet = .editor(nil)
        } label: {
            Label("Konto anlegen", systemImage: "wallet.pass")
        }
        .accessibilityLabel("Konto manuell anlegen, zum Beispiel Bargeld")
        .accessibilityIdentifier("account-add-manual-button")
    }

    private var addDataSourceButton: some View {
        Button {
            activeSheet = .addDataSource
        } label: {
            Label("Datenquelle hinzufügen", systemImage: "plus.circle.fill")
        }
        .accessibilityLabel("Neue Datenquelle hinzufügen oder Datei importieren")
        .accessibilityIdentifier("account-add-source-button")
    }

    /// Löschen wird nur für manuell angelegte Konten angeboten.
    private func deleteAction(for account: Account) -> (@MainActor () async -> Void)? {
        guard model.canDeleteManually(account) else { return nil }
        return { @MainActor [model] in await model.deleteManualAccount(account) }
    }

    var body: some View {
        kontenContent
        .workspaceToolbar {
            ToolbarItem(placement: .primaryAction) {
                addManualAccountButton
                    .help("Konto manuell anlegen, zum Beispiel Bargeld")
            }
            ToolbarItem(placement: .primaryAction) {
                addDataSourceButton
                    .help("Bank verbinden oder Datei importieren")
            }
            ToolbarItem(placement: .primaryAction) {

            #if !os(macOS)
                PrivacyToggleToolbarButton()
            #endif
            }
        }
        .workspaceNavigationTitle(String(localized: "Konten & Verbindungen"))
        .workspaceHeading(String(localized: "Konten"), subtitle: String(localized: "Deine Konten und Bankverbindungen an einem Ort"), eyebrow: String(localized: "Daten"))
        .workspaceCanvas()
        .task(id: model.dataRevision) {
            await model.load()
            await consumePendingRoute()
        }
        .onChange(of: pendingRoute.wrappedValue) { _, route in
            // WP24/MacUX-Perf: Deep-Link bei bereits sichtbarem Screen.
            guard route != nil else { return }
            Task { await consumePendingRoute() }
        }
    }

    private var kontenContent: some View {
        Group {
            if model.isLoading, model.accounts.isEmpty {
                LoadingStateView()
            } else if let errorMessage = model.errorMessage,
                      model.accounts.isEmpty,
                      model.connections.isEmpty {
                ErrorStateView(message: errorMessage) {
                    Task { await model.load() }
                }
            } else if model.accounts.isEmpty, model.connections.isEmpty, model.disconnectedAccounts.isEmpty {
                emptyState
                    .accessibilityIdentifier("screen-ready-accounts")
            } else {
                accountsContent
                    .accessibilityIdentifier("screen-ready-accounts")
            }
        }
        // Sheet auf äußerster Ebene: funktioniert für Empty UND populated
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addDataSource:
                AddDataSourceView(
                    dependencies: model.dependencies,
                    onDismiss: { activeSheet = nil },
                    onManualAccount: { activeSheet = .editor(nil) }
                )
                    #if os(macOS)
                    .frame(width: 520, height: 620)
                    #endif
            case .renewal(let connection, let purpose):
                BankConnectView(dependencies: model.dependencies, renewal: (connection, purpose)) {
                    activeSheet = nil
                    Task { await model.load() }
                }
                    #if os(macOS)
                    .frame(width: 520, height: 620)
                    #endif
            case .editor(let account):
                AccountEditorSheet(
                    dependencies: model.dependencies,
                    editing: account,
                    transactionCount: account.flatMap { edited in model.accounts.first { $0.id == edited.id }?.transactionCount } ?? 0,
                    onSaved: { Task { await model.load() } }
                )
            case .account(let account):
                AccountDetailSheet(
                    account: account,
                    connectionName: model.connections.first(where: { $0.id == account.connectionID })?.displayName,
                    lastSync: model.connections.first(where: { $0.id == account.connectionID })?.lastSuccessfulSyncAt,
                    dependencies: model.dependencies,
                    onDelete: deleteAction(for: account)
                )
            }
        }
        .alert(
            "Verbindung trennen?",
            isPresented: Binding(
                get: { connectionPendingDisconnect != nil },
                set: { if !$0 { connectionPendingDisconnect = nil } }
            ),
            presenting: connectionPendingDisconnect
        ) { connection in
            Button("Verbindung trennen", role: .destructive) {
                connectionPendingDisconnect = nil
                Task { await model.disconnect(connection: connection) }
            }
            Button("Abbrechen", role: .cancel) {
                connectionPendingDisconnect = nil
            }
        } message: { connection in
            Text("Die Verbindung zu \(connection.displayName) wird entfernt. Zugehörige Konten wandern in „Getrennte Konten“; bereits importierte Transaktionen bleiben erhalten, bis du das Konto dort löschst.")
        }
        .alert(
            "Konto und Buchungen löschen?",
            isPresented: Binding(
                get: { accountPendingDeletion != nil },
                set: { if !$0 { accountPendingDeletion = nil } }
            ),
            presenting: accountPendingDeletion
        ) { summary in
            Button("Konto löschen", role: .destructive) {
                accountPendingDeletion = nil
                Task { await model.deleteDisconnectedAccount(summary.account) }
            }
            Button("Abbrechen", role: .cancel) {
                accountPendingDeletion = nil
            }
        } message: { summary in
            Text("„\(summary.account.name.trimmingCharacters(in: .whitespaces))“ (\(summary.account.presentationIdentifier)) wird mit \(summary.transactionCount) Buchungen endgültig entfernt. Das lässt sich nicht rückgängig machen.")
        }
    }

    /// WP24: Deep-Link-Konsum: Konto-Detail exakt öffnen.
    private func consumePendingRoute() async {
        guard case .account(let accountID) = pendingRoute.wrappedValue else { return }
        pendingRoute.wrappedValue = nil
        if let account = try? await model.dependencies.accountRepository.account(id: accountID) {
            activeSheet = .account(account)
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            title: String(localized: "Noch keine Konten"),
            message: String(localized: "Verbinde deine Bank über Enable Banking oder importiere einen CSV-/Excel-Export. Der Bankzugriff ist ausschließlich lesend."),
            systemImage: "building.columns.fill"
        ) {
            addDataSourceButton
                .buttonStyle(.borderedProminent)
            addManualAccountButton
                .buttonStyle(.bordered)
        }
    }

    private var accountsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.l) {
                if let errorMessage = model.errorMessage {
                    InlineNotice(message: errorMessage, tone: .warning)
                }
                if !model.connections.isEmpty {
                    PageSection(String(localized: "Bankverbindungen")) {
                        VStack(spacing: 0) {
                            ForEach(model.connections) { connection in
                                connectionRow(connection)
                                if connection.id != model.connections.last?.id { Divider() }
                            }
                        }
                        if let msg = syncMessage {
                            Text(msg).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if !model.accounts.isEmpty {
                    PageSection(String(localized: "Deine Konten"), subtitle: String(localized: "Kontostand bei Konten mit Anfangsbestand, sonst Netto der erfassten Buchungen")) {
                        VStack(spacing: 0) {
                            ForEach(model.accounts) { summary in
                                row(for: summary)
                                if summary.id != model.accounts.last?.id { Divider().padding(.leading, 52) }
                            }
                        }
                    }
                }
                if !model.disconnectedAccounts.isEmpty {
                    PageSection(String(localized: "Getrennte Konten"), subtitle: String(localized: "Ohne Verbindung: Ihre Buchungen zählen weiter in Übersicht, Analyse und Budgets mit")) {
                        VStack(spacing: 0) {
                            ForEach(model.disconnectedAccounts) { summary in
                                disconnectedRow(for: summary)
                                if summary.id != model.disconnectedAccounts.last?.id { Divider().padding(.leading, 52) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, AppLayout.pageHorizontalPadding)
            .padding(.bottom, AppSpacing.l)
            .frame(maxWidth: AppLayout.summaryMaximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .workspaceCanvas()
        .refreshable { await model.load() }
    }

    private func connectionRow(_ connection: Connection) -> some View {
        let isSyncing = syncingConnectionID == connection.id
        let warning = model.consentWarning(for: connection)
        let needsReconnect = model.connectionNeedsReconnect(connection)

        return VStack(alignment: .leading, spacing: AppSpacing.s) {
            HStack(spacing: AppSpacing.m) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    HStack(spacing: AppSpacing.s) {
                        IconTile(systemName: "building.columns.fill", color: AppPalette.information, size: 28)
                        Text(connection.displayName)
                            .fontWeight(.medium)
                    }
                    if let last = connection.lastSuccessfulSyncAt {
                        Text("Zuletzt aktualisiert: \(last.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated).locale(.current)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Noch nie synchronisiert")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: AppSpacing.s)
                StatusBadge(
                    title: model.connectionStatusLabel(for: connection),
                    tone: needsReconnect || model.connectionDataIsStale(connection) ? .warning : .positive
                )
                if needsReconnect {
                    Button("Neu verbinden", systemImage: "link.badge.plus") {
                        activeSheet = connection.provider == .enablebanking
                            ? .renewal(connection, .reauthorize)
                            : .addDataSource
                    }
                    .controlSize(.small)
                }
                if isSyncing {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Verbindung wird aktualisiert")
                } else {
                    Button {
                        syncingConnectionID = connection.id
                        Task {
                            syncMessage = await model.sync(connection: connection)
                            syncingConnectionID = nil
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Verbindung aktualisieren")
                    .help("Umsätze dieser Verbindung jetzt abrufen")
                    Menu {
                        if connection.provider == .enablebanking {
                            Button("Neu autorisieren …") {
                                activeSheet = .renewal(connection, .reauthorize)
                            }
                            Button("Ältere Umsätze anfragen …") {
                                activeSheet = .renewal(connection, .olderTransactions)
                            }
                        }
                        Button("Verbindung trennen", role: .destructive) {
                            connectionPendingDisconnect = connection
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .accessibilityLabel("Verbindungsoptionen")
                    .help("Weitere Optionen")
                }
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppPalette.warning)
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }

    private func disconnectedRow(for summary: AccountSummary) -> some View {
        HStack(spacing: AppSpacing.m) {
            IconTile(systemName: summary.account.type.systemImage, color: .gray, size: 36)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(summary.account.name.trimmingCharacters(in: .whitespaces))
                    .fontWeight(.medium)
                Text(
                    [
                        summary.account.presentationIdentifier,
                        summary.account.type.displayName,
                        String(localized: "\(summary.transactionCount) Transaktionen")
                    ].joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: AppSpacing.s)
            MoneyText(money: summary.netMovement, signed: true)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Löschen…", role: .destructive) {
                accountPendingDeletion = summary
            }
            .controlSize(.small)
            .accessibilityLabel("Getrenntes Konto \(summary.account.name) mit \(summary.transactionCount) Buchungen löschen")
            .accessibilityIdentifier("account-delete-disconnected-" + summary.account.id.uuidString)
        }
        .padding(.vertical, AppSpacing.s)
    }

    private func row(for summary: AccountSummary) -> some View {
        Button {
            activeSheet = .account(summary.account)
        } label: {
            accountRowContent(summary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(RowHighlightButtonStyle())
        .accessibilityIdentifier("account-detail-" + summary.account.id.uuidString)
        .accessibilityLabel(
            summary.balance.map { balance in
                String(localized: "Konto \(summary.account.name), \(summary.account.presentationIdentifier), aktueller Stand: \(PrivacyAwareMoney.accessibilityLabel(balance, privacy: privacyState, signed: true)), \(summary.transactionCount) Transaktionen, Detail öffnen")
            } ?? String(localized: "Konto \(summary.account.name), \(summary.account.presentationIdentifier), Netto der erfassten Buchungen, kein aktueller Kontostand: \(PrivacyAwareMoney.accessibilityLabel(summary.netMovement, privacy: privacyState, signed: true)), \(summary.transactionCount) Transaktionen, Detail öffnen")
        )
    }

    private func accountRowContent(_ summary: AccountSummary) -> some View {
        HStack(spacing: AppSpacing.m) {
            IconTile(systemName: summary.account.type.systemImage, color: accountColor(summary.account.type), size: 36)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(summary.account.name)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text(
                    [
                        summary.account.hasExternalIdentifier ? summary.account.presentationIdentifier : nil,
                        summary.account.type.displayName,
                        String(localized: "\(summary.transactionCount) Transaktionen")
                    ].compactMap { $0 }.joined(separator: " · ")
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !summary.foreignCurrencies.isEmpty {
                    Text("Fremdwährungen (\(summary.foreignCurrencies.map(\.rawValue).sorted().joined(separator: ", "))) sind nicht enthalten")
                        .font(.caption2)
                        .foregroundStyle(AppPalette.warning)
                }
            }
            Spacer(minLength: AppSpacing.s)
            // Mit Anfangsbestand gibt es einen echten Stand (Minus = rot).
            // Netto der Buchungen ist kein Kontostand: Minus bleibt neutral,
            // damit eine Karte mit Ausgaben nicht wie ein Problem aussieht.
            VStack(alignment: .trailing, spacing: 2) {
                if let balance = summary.balance {
                    MoneyText(money: balance, signed: true, tintsNegative: true)
                        .font(.system(size: 16, weight: .semibold))
                    Text("Stand")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    MoneyText(money: summary.netMovement, signed: true)
                        .font(.system(size: 16, weight: .semibold))
                    Text("Netto-Bewegung")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
    }

    private func accountColor(_ type: AccountType) -> Color {
        switch type {
        case .checking: CategoryColorToken.blue.color
        case .creditCard: CategoryColorToken.purple.color
        case .cryptoCard: CategoryColorToken.orange.color
        case .savings: CategoryColorToken.green.color
        case .cash: CategoryColorToken.green.color
        default: CategoryColorToken.gray.color
        }
    }
}
