import Combine
import Foundation
import Observation
import Sparkle
import SwiftUI

/// Updates über Sparkle (wie in PDFdownsize).
///
/// Sparkle fragt höchstens einmal am Tag die Update-Liste (`appcast.xml` im
/// GitHub-Repo) ab, lädt eine neuere Version aus den GitHub-Releases, prüft
/// ihre EdDSA-Signatur gegen `SUPublicEDKey`, ersetzt die App und startet sie
/// neu. Abschaltbar im App-Menü.
///
/// Debug-Builds und Testläufe starten den Updater nicht: Ein Entwicklungs-
/// stand soll sich nicht selbst durch ein Release ersetzen, und Tests greifen
/// nie ins Netz.
@MainActor
@Observable
final class UpdateChecker {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: AnyCancellable?

    let isActive: Bool
    private(set) var canCheck = false

    /// Spiegelt Sparkles eigene Einstellung (`SUEnableAutomaticChecks`).
    var checksAutomatically: Bool {
        didSet {
            guard controller.updater.automaticallyChecksForUpdates != checksAutomatically else { return }
            controller.updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        let underTest = environment["XCTestConfigurationFilePath"] != nil
        isActive = !isDebugBuild && !underTest
        controller = SPUStandardUpdaterController(
            startingUpdater: isActive,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        guard isActive else { return }
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }

    /// „Nach Updates suchen …": Sparkle zeigt Ergebnis und Ablauf selbst.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Updates in den Einstellungen: dasselbe wie im App-Menü, nur auffindbarer.
struct UpdateSettingsSection: View {
    @Bindable var updateChecker: UpdateChecker

    var body: some View {
        if updateChecker.isActive {
            Toggle("Automatisch nach Updates suchen", isOn: $updateChecker.checksAutomatically)
                .toggleStyle(.switch)
            Button("Jetzt nach Updates suchen …") {
                updateChecker.checkForUpdates()
            }
            .disabled(!updateChecker.canCheck)
            Text("Einmal am Tag prüft die App, ob es eine neue Version gibt. Updates sind signiert und werden erst nach deiner Bestätigung installiert.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("In Entwicklungs-Builds sucht die App nicht nach Updates.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
