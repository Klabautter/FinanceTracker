import SwiftUI
import os

#if os(macOS)
/// WP24 (§188, Release-Rehearsal-Befund): Die sandboxed Release-App
/// präsentiert unter macOS 26 (26.6.1) bei Launch über LaunchServices
/// kein SwiftUI-Fenster, reproduziert via A/B (Debug unsandboxed: 1
/// Fenster; Release sandboxed: 0 Fenster, auch über Finder-open). Der
/// Delegat aktiviert die App und order-front das erste Fenster explizit.
/// DEBUG präsentiert ohnehin (unsandboxed Entitlements);
/// der Fix läuft bewusst in ALLEN Konfigurationen.
@MainActor
final class WindowPresentationAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        presentMainWindowIfNeeded()
        // Zweiter Anlauf, falls die SwiftUI-Szene das Fenster erst nach dem
        // Delegat-Callback erzeugt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.presentMainWindowIfNeeded()
        }
    }

    private func presentMainWindowIfNeeded() {
        let logger = Logger(subsystem: "de.klabautter.FinanceTracker", category: "WindowPresentation")
        NSApp.activate(ignoringOtherApps: true)
        var visibleCount = 0
        var canBecomeMainCount = 0
        for window in NSApp.windows {
            if window.isVisible { visibleCount += 1 }
            if window.canBecomeMain { canBecomeMainCount += 1 }
        }
        logger.notice("WindowPresentation check: \(NSApp.windows.count, privacy: .public) windows, visible=\(visibleCount, privacy: .public), canBecomeMain=\(canBecomeMainCount, privacy: .public)")
        #if DEBUG
        if let size = AppLaunchEnvironment.live.visualQAWindowSize,
           let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.setContentSize(size)
        }
        #endif
        let hasVisibleMainWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        guard !hasVisibleMainWindow else { return }
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
#endif

extension Scene {
    @SceneBuilder
    var financeWindowConfiguration: some Scene {
        #if os(macOS)
        self
            .defaultSize(
                width: Self.visualQAWindowSize.width,
                height: Self.visualQAWindowSize.height
            )
            .windowResizability(.contentMinSize)
        #else
        self
        #endif
    }

    #if os(macOS)
    private static var visualQAWindowSize: CGSize {
        #if DEBUG
        if let size = AppLaunchEnvironment.live.visualQAWindowSize { return size }
        #endif
        return CGSize(width: 1240, height: 800)
    }
    #endif
}

@main
struct FinanceTrackerApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(WindowPresentationAppDelegate.self) private var appDelegate
    @State private var updateChecker = UpdateChecker()
    #endif
    @State private var bootstrapper = AppBootstrapper()
    @State private var privacyState = PrivacyPresentationState(
        forcedHidesAmounts: AppLaunchEnvironment.live.forcedPrivacyHidesAmounts
    )
    var body: some Scene {
        WindowGroup {
            Group {
                switch bootstrapper.state {
                case .loading:
                    ProgressView("Öffne lokale Datenbank…")

                case .ready(let dependencies):
                    RootView(dependencies: dependencies)
                        .task {
                            // MacUX-Automatisierung: System-Katalog (Standard-
                            // kategorien + Händler-Regeln) für JEDER Installation,
                            // inkl. einmaligem Rückfill offener Buchungen.
                            await SystemCatalogSeeder(dependencies: dependencies).seedIfNeeded()
                            // Doppelte nach Neu-Autorisierung zusammenführen (Enable Banking).
                            _ = try? await EnableBankingExternalIDMigration(
                                transactionRepository: dependencies.transactionRepository
                            ).run()
                            // Fixkosten eines gelöschten Kontos aufs verbleibende umhängen.
                            _ = try? await RelinkOrphanedCommitments(
                                commitmentRepository: dependencies.recurringCommitmentRepository,
                                accountRepository: dependencies.accountRepository,
                                transactionRepository: dependencies.transactionRepository
                            ).run()
                        }

                case .failed(let message):
                    StorageRecoveryView(message: message) {
                        bootstrapper.start()
                    }
                }
            }
            #if DEBUG
            #if os(macOS)
            // WP36: QA-Appearance setzen, sobald NSApp verfügbar ist.
            .task { applyVisualQAAppearance() }
            #endif
            #endif
            .environment(privacyState)
        }
        .financeWindowConfiguration
        #if os(macOS)
        // Stellt sicher, dass beim Start immer ein Fenster präsentiert wird,
        // auch bei direktem Binary-Launch (z. B. durch XCUITest).
        .defaultLaunchBehavior(.presented)
        .commands {
            FinanceCommands(updateChecker: updateChecker)
        }
        #endif

        #if os(macOS)
        Settings {
            settingsContent
                .environment(privacyState)
        }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var settingsContent: some View {
        if case .ready(let dependencies) = bootstrapper.state {
            // P1 UX: NavigationStack, damit der Datenquellen-Link auf
            // Konten & Verbindungen auch im Settings-Fenster funktioniert.
            NavigationStack {
                SettingsView(
                    dependencies: dependencies,
                    updatesContent: AnyView(UpdateSettingsSection(updateChecker: updateChecker))
                )
            }
            .frame(width: 620, height: 680)
        } else {
            Text("Lokale Daten nicht verfügbar.")
                .frame(width: 420, height: 240)
        }
    }
    #endif

    #if DEBUG
    #if os(macOS)
    /// WP36: Zuverlässige QA-Appearance via NSApp (wirkt auf Fenster-Chrome
    /// UND Content). Achtung Fallstrick: preferredColorScheme/colorScheme am
    /// Window-Root hängt die macOS-26-Fenster-Präsentation auf; niemals
    /// dorthin zurückbauen.
    private func applyVisualQAAppearance() {
        guard let appearance = AppLaunchEnvironment.live.visualQAAppearance else { return }
        NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    }
    #endif
    #endif

}
