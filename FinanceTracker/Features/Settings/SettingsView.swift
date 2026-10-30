import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let dependencies: AppDependencies
    /// P1 UX: Echter Navigations-Link auf Konten & Verbindungen. Hosts mit
    /// eigener Navigation (z. B. Sidebar-Steuerung) übergeben einen
    /// Callback; ohne Callback fällt die Sektion auf einen internen
    /// `NavigationLink` zurück (iOS-Tab bzw. macOS-Settings-Fenster).
    var onShowAccounts: (() -> Void)?
    /// Plattform-Zusatz unter „Allgemein“, z. B. Updates (macOS).
    var updatesContent: AnyView?
    @State private var model: SettingsModel
    @Environment(PrivacyPresentationState.self) private var privacyState
    @State private var exportDocument: TransactionsCSVDocument?
    @State private var showsCSVExporter = false
    @State private var backupDocument: BackupPackageDocument?
    @State private var showsBackupExporter = false
    @State private var exportErrorMessage: String?
    /// Bestätigung nach erfolgreichem Speichern (Dateiname, kein Pfad).
    @State private var exportSuccessMessage: String?
    /// WP30 (§210): Große Exporte zeigen Fortschritt statt stiller Blockade.
    @State private var showsBackupImporter = false
    @State private var showsRestoreConfirmation = false
    init(dependencies: AppDependencies, onShowAccounts: (() -> Void)? = nil, updatesContent: AnyView? = nil) {
        self.dependencies = dependencies
        self.onShowAccounts = onShowAccounts
        self.updatesContent = updatesContent
        _model = State(initialValue: SettingsModel(dependencies: dependencies))
    }

    var body: some View {
        settingsLayout
        .workspaceNavigationTitle(String(localized: "Einstellungen"))
        #if !os(macOS)
        .workspaceHeading(String(localized: "Einstellungen"), subtitle: String(localized: "Passe FinanceTracker an deinen Alltag an"))
        #endif
        .workspaceCanvas()
        .task { await model.loadFXRates() }
        .task { await model.loadCashAccounts() }
        .fileImporter(isPresented: $showsBackupImporter, allowedContentTypes: [.init(exportedAs: "de.klabautter.ftbackup")]) { result in
            switch result {
            case .success(let url):
                Task {
                    await model.prepareRestore(from: url)
                    showsRestoreConfirmation = model.preparedRestore != nil
                }
            case .failure(let error): exportErrorMessage = error.localizedDescription
            }
        }
        .alert("Daten durch Backup ersetzen?", isPresented: $showsRestoreConfirmation) {
            Button("Abbrechen", role: .cancel) { model.cancelRestore() }
            Button("Wiederherstellen", role: .destructive) { Task { await model.confirmRestore() } }
        } message: {
            Text("\(model.preparedRestore?.summary ?? "")\nAlle bestehenden Daten werden ersetzt. Zuvor wird eine vollständige Sicherheitskopie gespeichert. Bankverbindungen benötigen gegebenenfalls eine neue Anmeldung.")
        }
        .fileExporter(
            isPresented: $showsCSVExporter,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: CSVExportService.defaultFileName()
        ) { result in
            switch result {
            case .success(let url):
                exportErrorMessage = nil
                exportSuccessMessage = String(localized: "Export gespeichert: \(url.lastPathComponent)")
            case .failure(let error):
                exportSuccessMessage = nil
                exportErrorMessage = String(localized: "Export fehlgeschlagen: \(error.localizedDescription)")
            }
        }
        .fileExporter(
            isPresented: $showsBackupExporter,
            document: backupDocument,
            contentType: UTType(exportedAs: "de.klabautter.ftbackup"),
            defaultFilename: "FinanceTracker-Backup-\(Date().formatted(.iso8601.year().month().day()))"
        ) { result in
            switch result {
            case .success(let url):
                exportErrorMessage = nil
                exportSuccessMessage = String(localized: "Backup gespeichert: \(url.lastPathComponent)")
            case .failure(let error):
                exportSuccessMessage = nil
                exportErrorMessage = String(localized: "Backup-Export fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    @ViewBuilder
    private var settingsLayout: some View {
        #if os(macOS)
        // Mac-typisch: Reiter oben im Einstellungsfenster statt einer
        // langen Seite.
        TabView {
            settingsTab { generalSections }
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
            settingsTab { privacySections }
                .tabItem { Label("Datenschutz", systemImage: "hand.raised") }
            settingsTab { accountSections }
                .tabItem { Label("Konten", systemImage: "building.columns") }
            settingsTab { dataSections }
                .tabItem { Label("Daten", systemImage: "externaldrive") }
        }
        #else
        Form { settingsSections }
            .financeFormStyle()
        #endif
    }

    #if os(macOS)
    private func settingsTab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.l, content: content)
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(AppSpacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    #endif

    private var settingsSections: some View {
        Group {
            generalSections
            privacySections
            accountSections
            dataSections
        }
    }

    @ViewBuilder
    private var generalSections: some View {
            settingsSection(String(localized: "Allgemein", comment: "Settings-Sektion: allgemeine Angaben")) {
                HStack {
                    Text("Basiswährung")
                    Spacer()
                    Text(model.baseCurrency.rawValue).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion).foregroundStyle(.secondary)
                }
            }

            if let updatesContent {
                settingsSection(String(localized: "Updates", comment: "Settings-Sektion: App-Updates")) {
                    updatesContent
                }
            }

            settingsSection(String(localized: "Wechselkurse", comment: "Settings-Sektion: Wechselkurse")) {
                FXRateStatusView(snapshot: model.fxSnapshot, isLoading: model.fxIsLoading, detailed: true)
                Text("Referenzwährung: \(model.baseCurrency.rawValue). Kurse werden täglich aktualisiert; ohne Verbindung gelten die zuletzt verfügbaren Kurse.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await model.refreshFXRates() }
                } label: {
                    Label("Kurse aktualisieren", systemImage: "arrow.clockwise")
                }
                .disabled(model.fxIsLoading)
                .accessibilityLabel("Wechselkurse jetzt aktualisieren")
            }

    }

    @ViewBuilder
    private var privacySections: some View {
            settingsSection(String(localized: "Datenschutz", comment: "Settings-Sektion: Datenschutz")) {
                Toggle(isOn: Binding(
                    get: { privacyState.hidesAmounts },
                    set: { privacyState.hidesAmounts = $0 }
                )) {
                    Label("Beträge verbergen", systemImage: privacyState.hidesAmounts ? "eye.slash" : "eye")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Beträge in der gesamten App verbergen oder anzeigen")
            }

            mitteilungenSection
    }

    @ViewBuilder
    private var accountSections: some View {
            @Bindable var model = model
            settingsSection(String(localized: "Bargeld", comment: "Settings-Sektion: Bargeld-Automatik")) {
                Picker("Abhebungen gutschreiben", selection: $model.cashWithdrawalTargetAccountID) {
                    Text("Aus").tag(UUID?.none)
                    ForEach(model.cashAccounts) { account in
                        Text(account.name).tag(UUID?.some(account.id))
                    }
                }
                .disabled(model.cashAccounts.isEmpty)
                .accessibilityLabel("Bargeldkonto für automatische Abhebungen")
                (model.cashAccounts.isEmpty
                    ? Text("Lege unter Konten ein Bargeldkonto an, dann kann die App Abhebungen am Geldautomaten automatisch als Umbuchung dorthin verbuchen.")
                    : Text("Erkannte Abhebungen (Geldautomat, Bargeldauszahlung) aus Bank-Sync und Datei-Import werden als Transfer gebucht und dem gewählten Bargeldkonto gutgeschrieben. Einzelne Buchungen gehen auch per Rechtsklick in den Transaktionen."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            settingsSection(String(localized: "Datenquellen", comment: "Settings-Sektion: Datenquellen")) {
                // P1 UX: Echter Navigations-Link auf Konten & Verbindungen
                // statt reiner Label-Sektion.
                if let onShowAccounts {
                    Button(action: onShowAccounts) {
                        HStack {
                            Label("Konten", systemImage: "building.columns")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Konten und Verbindungen öffnen")
                    .accessibilityIdentifier("settings-show-accounts")
                } else {
                    NavigationLink {
                        AccountsView(dependencies: dependencies, pendingRoute: .constant(nil))
                    } label: {
                        Label("Konten", systemImage: "building.columns")
                    }
                    .accessibilityLabel("Konten und Verbindungen öffnen")
                    .accessibilityIdentifier("settings-show-accounts")
                }
                Text("CSV-, Excel- und PDF-Importe werden lokal verarbeitet. FinanceTracker führt keine Zahlungen aus.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var dataSections: some View {
            settingsSection(String(localized: "Daten & Export", comment: "Settings-Sektion: Daten und Export")) {
                Menu {
                    Button("Transaktionen als CSV exportieren", systemImage: "square.and.arrow.up") {
                    Task {
                        exportSuccessMessage = nil
                        exportDocument = await model.prepareCSVExport()
                        showsCSVExporter = exportDocument != nil
                    }
                }
                    .disabled(model.isBusyWithData)
                .accessibilityLabel("Alle Transaktionen als CSV-Datei exportieren")
                    Button("Vollständiges Backup exportieren", systemImage: "archivebox") {
                    Task {
                        exportSuccessMessage = nil
                        backupDocument = await model.prepareBackupExport()
                        showsBackupExporter = backupDocument != nil
                    }
                }
                    .disabled(model.isBusyWithData)
                    Button("Datenbackup ohne Belege exportieren", systemImage: "archivebox") {
                    Task {
                        exportSuccessMessage = nil
                        backupDocument = await model.prepareBackupExport(includeAttachments: false)
                        showsBackupExporter = backupDocument != nil
                    }
                }
                    .disabled(model.isBusyWithData)
                } label: {
                    Label("Daten exportieren", systemImage: "square.and.arrow.up")
                }
                .disabled(model.isBusyWithData)
                Text("Das vollständige Backup enthält alles, auch deine Belege, und lässt sich komplett wiederherstellen. Ohne Belege ist es kleiner, Belegdateien fehlen dann nach einer Wiederherstellung.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Backup wiederherstellen…", systemImage: "arrow.counterclockwise") {
                    showsBackupImporter = true
                }
                .disabled(model.isBusyWithData || dependencies.backupRestoreService == nil)
                .accessibilityLabel("Backup-Datei auswählen und vor der Wiederherstellung prüfen")
                if model.isBusyWithData {
                    ProgressView(model.isRestoring ? String(localized: "Backup wird verarbeitet…") : String(localized: "Export wird erstellt…"))
                }
                if let message = model.dataMessage {
                    Text(message).font(.footnote).textSelection(.enabled)
                    #if os(macOS)
                    if let safetyURL = model.lastSafetyBackupURL {
                        Button("Sicherheitskopie im Finder zeigen") {
                            NSWorkspace.shared.activateFileViewerSelecting([safetyURL])
                        }
                        .controlSize(.small)
                    }
                    #endif
                }

                if let exportSuccessMessage {
                    Label(exportSuccessMessage, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(AppPalette.positive)
                        .accessibilityIdentifier("settings-export-success")
                }

                if let exportErrorMessage {
                    Label(exportErrorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppPalette.critical)
                }

                // Privacy Mode ist UI-Presentation: Exporte enthalten immer
                // die echten Daten, die UI muss das erklären.
                if privacyState.hidesAmounts {
                    Label(PrivacyAwareMoney.exportContainsRealAmountsHint, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

    }

    @ViewBuilder
    private var mitteilungenSection: some View {
            settingsSection(String(localized: "Mitteilungen", comment: "Settings-Sektion: Mitteilungen")) {
                Toggle(isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { newValue in Task { await model.setNotificationsEnabled(newValue) } }
                )) {
                    Label("Mitteilungen", systemImage: model.notificationsEnabled ? "bell.fill" : "bell")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.isUpdatingNotifications)
                .accessibilityLabel("Lokale Mitteilungen aktivieren oder deaktivieren")
                .accessibilityIdentifier("notifications-opt-in-toggle")

                if model.isUpdatingNotifications {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Mitteilungen werden eingerichtet…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Mitteilungen werden eingerichtet")
                }

                Text("Erhalte Hinweise zu Budgets, fälligen Zahlungen und Bankverbindungen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if model.notificationsEnabled {
                    Button {
                        Task { await model.refreshLocalNotifications() }
                    } label: {
                        Label("Hinweise jetzt aktualisieren", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isUpdatingNotifications)
                    .accessibilityLabel("Hinweise aus lokalen Daten aktualisieren")
                }

                if let notificationMessage = model.notificationMessage {
                    Label(notificationMessage, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Hinweis zu Mitteilungen: \(notificationMessage)")
                }
            }

    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text(title).eyebrowStyle()
                .padding(.leading, AppSpacing.xs)
            VStack(alignment: .leading, spacing: AppSpacing.m, content: content)
                .financeCard(padding: AppSpacing.l)
        }
        #else
        Section(title, content: content)
        #endif
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }
}

#if DEBUG
#Preview("Einstellungen") {
    NavigationStack {
        SettingsView(dependencies: PreviewDependencies.dependencies())
    }
    .environment(PrivacyPresentationState())
}
#endif
