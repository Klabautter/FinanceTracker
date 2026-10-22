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

    private let factory: () throws -> AppDependencies

    init(factory: @escaping () throws -> AppDependencies = {
        if AppLaunchEnvironment.live.isUITestingStorageErrorMode {
            throw AppBootstrapSimulatedError.simulatedStorageFailure
        }
        return try AppDependencies.live()
    }) {
        self.factory = factory
        start()
    }

    func start() {
        state = .loading
        do {
            state = .ready(try factory())
        } catch {
            state = .failed(String(localized: "Die lokalen Daten konnten nicht geöffnet werden. Es wurden keine Daten gelöscht oder verändert."))
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
