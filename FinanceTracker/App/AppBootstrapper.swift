import Foundation
import SwiftUI

/// Simulierter Storage-Fehler für den Launch State `-ui-testing-error-storage`.
enum AppBootstrapSimulatedError: Error {
    case simulatedStorageFailure
}

@MainActor
@Observable
final class AppBootstrapper {
    enum State {
        case loading
        case ready(AppDependencies)
        case failed(String)
    }

    private(set) var state: State = .loading

    private let factory: @Sendable () throws -> AppDependencies
    private var openTask: Task<Void, Never>?

    init(factory: @escaping @Sendable () throws -> AppDependencies = {
        if AppLaunchEnvironment.live.isUITestingStorageErrorMode {
            throw AppBootstrapSimulatedError.simulatedStorageFailure
        }
        return try AppDependencies.live()
    }) {
        self.factory = factory
        start()
    }

    /// Öffnet die Datenbank (inklusive Migration) im Hintergrund: Eine
    /// große oder zu migrierende Datenbank blockiert so nicht das Fenster,
    /// und der Ladezustand ist tatsächlich zu sehen (Rule 24).
    func start() {
        state = .loading
        openTask?.cancel()
        let factory = factory
        openTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try factory() }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let dependencies):
                self.state = .ready(dependencies)
            case .failure:
                self.state = .failed(String(localized: "Die lokalen Daten konnten nicht geöffnet werden. Es wurden keine Daten gelöscht oder verändert."))
            }
        }
    }
}

struct StorageRecoveryView: View {
    let message: String
    let retryAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Lokale Daten konnten nicht geöffnet werden", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("\(message)\n\nFinanceTracker hat keine Daten gelöscht oder verändert.")
        } actions: {
            Button("Erneut versuchen", action: retryAction)
                .buttonStyle(.borderedProminent)
        }
    }
}
