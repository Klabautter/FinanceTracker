import Foundation

/// Ergebnis eines Sammelabrufs über alle verbundenen Banken.
struct BankSyncRunSummary: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        let connectionID: UUID
        let connectionName: String
        let kind: SyncFailureKind
    }

    /// Verbindung, deren Zustimmung abgelaufen ist: nicht abgerufen.
    struct Reauthorization: Equatable, Sendable {
        let connectionID: UUID
        let connectionName: String
    }

    let trigger: BankSyncPolicy.Trigger
    var syncedConnectionCount = 0
    var importedCount = 0
    var updatedCount = 0
    var failures: [Failure] = []
    var reauthorizations: [Reauthorization] = []
    /// Die Liste der Verbindungen ließ sich nicht lesen.
    var couldNotLoadConnections = false

    var hasProblems: Bool {
        couldNotLoadConnections || !failures.isEmpty || !reauthorizations.isEmpty
    }

    /// Welche Probleme gemeldet werden, unabhängig von Zählern: Dieselbe
    /// Meldung soll nach dem Schließen nicht bei jedem Lauf wiederkommen.
    var problemSignature: Set<String> {
        var signature = Set(failures.map { "\($0.connectionID.uuidString)|\($0.kind.rawValue)" })
        signature.formUnion(reauthorizations.map { "\($0.connectionID.uuidString)|reauthorization" })
        if couldNotLoadConnections { signature.insert("connections-unreadable") }
        return signature
    }

    /// Nutzer-Text ohne Provider-Jargon und ohne Secrets.
    var message: String {
        if couldNotLoadConnections {
            return String(localized: "Die Bankverbindungen konnten nicht geladen werden.")
        }
        var parts: [String] = []
        if syncedConnectionCount == 1 {
            parts.append(String(localized: "1 Bank aktualisiert: \(importedCount) neu, \(updatedCount) aktualisiert."))
        } else if syncedConnectionCount > 1 {
            parts.append(String(localized: "\(syncedConnectionCount) Banken aktualisiert: \(importedCount) neu, \(updatedCount) aktualisiert."))
        }

        let retryNames = failures.filter { $0.kind == .transientRetry }.map(\.connectionName)
        if !retryNames.isEmpty {
            parts.append(String(localized: "Abruf fehlgeschlagen: \(retryNames.formatted(.list(type: .and))). Bitte später erneut versuchen."))
        }
        let renewNames = reauthorizations.map(\.connectionName)
            + failures.filter { $0.kind != .transientRetry }.map(\.connectionName)
        if !renewNames.isEmpty {
            parts.append(String(localized: "Zugang erneuern: \(renewNames.formatted(.list(type: .and))). Das geht unter Konten."))
        }
        if parts.isEmpty {
            return String(localized: "Keine Bankverbindung zum Aktualisieren.")
        }
        return parts.joined(separator: " ")
    }
}

enum BankSyncCoordinatorError: LocalizedError {
    /// Die Verbindung wurde getrennt, während der Abruf wartete.
    case connectionRemoved

    var errorDescription: String? {
        String(localized: "Diese Bankverbindung gibt es nicht mehr.")
    }
}

/// Eine Stelle für alle Bankabrufe: der Knopf an einer Verbindung, der erste
/// Abruf beim Verbinden, „Alle aktualisieren“ und der automatische Abruf
/// laufen hier nacheinander, nie zwei gleichzeitig. Eine Instanz pro App
/// (`AppDependencies`), kein Singleton; die Abhängigkeiten kommen je Aufruf.
@MainActor
@Observable
final class BankSyncCoordinator {
    private(set) var syncingConnectionIDs: Set<UUID> = []
    private(set) var isSyncingAll = false
    /// Letzter Sammelabruf, der etwas zu melden hatte.
    private(set) var lastSummary: BankSyncRunSummary?
    /// Verbindungen, die „Alle aktualisieren“ anfassen würde.
    private(set) var syncableConnectionCount = 0

    @ObservationIgnored private let policy: BankSyncPolicy
    @ObservationIgnored private let healthEvaluator = ConnectionHealthEvaluator()
    /// Fehlversuche in Folge und die Wartezeit der Automatik danach. Nur im
    /// Speicher: Ein Neustart der App darf es einmal erneut versuchen.
    @ObservationIgnored private var consecutiveFailures: [UUID: Int] = [:]
    @ObservationIgnored private var automaticNotBefore: [UUID: Date] = [:]
    /// Der Server hat den Zugang abgelehnt: bis zu einem erfolgreichen
    /// Abruf kein automatischer Versuch mehr, nur der Hinweis.
    @ObservationIgnored private var rejectedConnectionIDs: Set<UUID> = []
    /// Probleme, die zuletzt gemeldet (und vielleicht geschlossen) wurden.
    @ObservationIgnored private var reportedProblemSignature: Set<String> = []
    @ObservationIgnored private var isBusy = false
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated init(policy: BankSyncPolicy = BankSyncPolicy()) {
        self.policy = policy
    }

    func isSyncing(_ connection: Connection) -> Bool {
        syncingConnectionIDs.contains(connection.id)
    }

    func dismissSummary() {
        lastSummary = nil
    }

    /// Zählt die abrufbaren Verbindungen (für die Sichtbarkeit des Knopfs)
    /// und räumt Meldungen zu inzwischen entfernten oder erneuerten
    /// Verbindungen ab.
    func refreshAvailability(dependencies: AppDependencies, now: Date = Date()) async {
        guard let connections = try? await dependencies.connectionRepository.connections() else { return }
        syncableConnectionCount = connections.count {
            policy.decision(for: $0, trigger: .manual, now: now) != .notSyncable
        }
        let needingReauthorization = Set(connections.filter {
            rejectedConnectionIDs.contains($0.id)
                || policy.decision(for: $0, trigger: .manual, now: now) == .needsReauthorization
        }.map(\.id))
        let existing = Set(connections.map(\.id))
        pruneSummary { summary in
            summary.failures.removeAll { !existing.contains($0.connectionID) }
            summary.reauthorizations.removeAll { !needingReauthorization.contains($0.connectionID) }
        }
    }

    /// Einzelabruf einer Verbindung. Läuft gerade ein anderer Abruf, wartet
    /// dieser, bis er an der Reihe ist.
    ///
    /// - Parameters:
    ///   - historyStart: Ausdrücklich angefragter Beginn der Umsätze (erster
    ///     Abruf beim Verbinden, „Ältere Umsätze“).
    ///   - provider: Abweichender Anbieter, sonst nach `Connection.provider`.
    func sync(
        _ connection: Connection,
        historyStart: Date? = nil,
        provider: (any BankDataProvider)? = nil,
        dependencies: AppDependencies
    ) async throws -> BankSyncResult {
        await acquire()
        defer { release() }
        // Aktuellen Stand lesen: Der Abruf schreibt die Verbindung zurück.
        // Wurde sie in der Wartezeit getrennt, legt er sie nicht wieder an.
        guard let current = try await dependencies.connectionRepository.connection(id: connection.id) else {
            throw BankSyncCoordinatorError.connectionRemoved
        }
        do {
            return try await performSync(current, historyStart: historyStart, provider: provider, dependencies: dependencies)
        } catch {
            recordFailure(error, for: current)
            throw error
        }
    }

    /// Ruft alle verbundenen Banken nacheinander ab. Automatisch nur, wenn
    /// die Einstellung an ist und der letzte Abruf lange genug zurückliegt.
    /// `nil`: nichts gestartet (Automatik aus oder Sammelabruf läuft schon).
    @discardableResult
    func syncAll(
        trigger: BankSyncPolicy.Trigger,
        dependencies: AppDependencies,
        now: Date = Date()
    ) async -> BankSyncRunSummary? {
        if trigger == .automatic, !dependencies.preferences.automaticBankSyncEnabled { return nil }
        guard !isSyncingAll else { return nil }
        isSyncingAll = true
        defer { isSyncingAll = false }

        var summary = BankSyncRunSummary(trigger: trigger)
        do {
            let connections = try await dependencies.connectionRepository.connections()
            for connection in connections.sorted(by: { $0.createdAt < $1.createdAt }) {
                // Fenster geschlossen oder App beendet: nicht weiter abrufen.
                if Task.isCancelled { break }
                await syncIfDue(connection.id, trigger: trigger, dependencies: dependencies, now: now, into: &summary)
            }
        } catch {
            BankSyncService.logger.error("Sammelabruf: Verbindungen nicht lesbar: \(String(describing: type(of: error)), privacy: .public)")
            summary.couldNotLoadConnections = true
        }

        await refreshAvailability(dependencies: dependencies, now: now)
        report(summary)
        return summary
    }

    /// Führt `operation` aus, während kein Abruf läuft und keiner startet
    /// (z. B. Backup wiederherstellen: Ein Abruf dazwischen schriebe alte
    /// Daten in den neuen Bestand).
    func runExclusively<T: Sendable>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    // MARK: - Privat

    private func syncIfDue(
        _ connectionID: UUID,
        trigger: BankSyncPolicy.Trigger,
        dependencies: AppDependencies,
        now: Date,
        into summary: inout BankSyncRunSummary
    ) async {
        await acquire()
        defer { release() }
        // Erst jetzt lesen: Ein Einzelabruf kann die Verbindung in der
        // Wartezeit schon aktualisiert oder der Nutzer sie getrennt haben.
        guard let connection = try? await dependencies.connectionRepository.connection(id: connectionID) else { return }

        let decision = policy.decision(
            for: connection,
            trigger: trigger,
            automaticNotBefore: automaticNotBefore[connectionID],
            now: now
        )
        // Vom Server abgelehnt: Die Automatik fragt nicht erneut an, sie
        // erinnert nur. Ein Klick versucht es wieder.
        let isRejected = trigger == .automatic && rejectedConnectionIDs.contains(connectionID)
        switch decision {
        case .notSyncable, .notDue:
            return
        case .needsReauthorization:
            summary.reauthorizations.append(.init(connectionID: connection.id, connectionName: connection.displayName))
        case .sync where isRejected:
            summary.reauthorizations.append(.init(connectionID: connection.id, connectionName: connection.displayName))
        case .sync:
            do {
                let result = try await performSync(connection, historyStart: nil, provider: nil, dependencies: dependencies)
                summary.syncedConnectionCount += 1
                summary.importedCount += result.importedCount
                summary.updatedCount += result.updatedCount
            } catch {
                guard let failure = recordFailure(error, for: connection, now: now) else { return }
                // Fehlt nur das Netz, meldet die Automatik nichts: Sie
                // versucht es gleich wieder.
                if failure == .offline, trigger == .automatic { return }
                summary.failures.append(.init(
                    connectionID: connection.id,
                    connectionName: connection.displayName,
                    kind: healthEvaluator.classify(syncError: error, connection: connection)
                ))
            }
        }
    }

    private func performSync(
        _ connection: Connection,
        historyStart: Date?,
        provider: (any BankDataProvider)?,
        dependencies: AppDependencies
    ) async throws -> BankSyncResult {
        syncingConnectionIDs.insert(connection.id)
        defer { syncingConnectionIDs.remove(connection.id) }
        let provider = provider ?? dependencies.bankProviderFactory.makeBankDataProvider(for: connection)
        let result = try await BankSyncService(dependencies: dependencies, provider: provider)
            .sync(connection: connection, historyStart: historyStart)
        consecutiveFailures[connection.id] = nil
        automaticNotBefore[connection.id] = nil
        rejectedConnectionIDs.remove(connection.id)
        // Meldungen zu dieser Verbindung sind damit erledigt; tritt das
        // Problem später wieder auf, wird es neu gemeldet.
        reportedProblemSignature = reportedProblemSignature.filter { !$0.hasPrefix(connection.id.uuidString) }
        pruneSummary { summary in
            summary.failures.removeAll { $0.connectionID == connection.id }
            summary.reauthorizations.removeAll { $0.connectionID == connection.id }
        }
        return result
    }

    /// Merkt sich einen Fehlversuch für die Wartezeit der Automatik.
    /// `nil`: abgebrochen (Fenster zu), kein Fehler der Bank.
    @discardableResult
    private func recordFailure(_ error: Error, for connection: Connection, now: Date = Date()) -> BankSyncPolicy.AttemptFailure? {
        guard let failure = Self.attemptFailure(
            for: error,
            kind: healthEvaluator.classify(syncError: error, connection: connection)
        ) else { return nil }
        let count = (consecutiveFailures[connection.id] ?? 0) + (failure == .offline ? 0 : 1)
        consecutiveFailures[connection.id] = count
        if let delay = policy.automaticRetryDelay(after: failure, consecutiveFailures: count) {
            automaticNotBefore[connection.id] = now.addingTimeInterval(delay)
        } else {
            rejectedConnectionIDs.insert(connection.id)
        }
        return failure
    }

    static func attemptFailure(for error: Error, kind: SyncFailureKind) -> BankSyncPolicy.AttemptFailure? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return nil
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return .offline
            default:
                break
            }
        }
        switch kind {
        case .transientRetry: return .transient
        case .reauthRequired, .blocked: return .needsUserAction
        }
    }

    /// Meldet das Ergebnis eines Sammelabrufs. Ein Klick wird immer
    /// gemeldet; die Automatik nur, wenn sich die Probleme geändert haben,
    /// sonst käme eine geschlossene Meldung bei jedem Lauf wieder.
    private func report(_ summary: BankSyncRunSummary) {
        switch summary.trigger {
        case .manual:
            lastSummary = summary
            reportedProblemSignature = summary.problemSignature
        case .automatic:
            guard summary.hasProblems, summary.problemSignature != reportedProblemSignature else { return }
            lastSummary = summary
            reportedProblemSignature = summary.problemSignature
        }
    }

    /// Nimmt erledigte Probleme aus der sichtbaren Meldung. Bleibt keines
    /// übrig, verschwindet eine Problemmeldung ganz.
    private func pruneSummary(_ prune: (inout BankSyncRunSummary) -> Void) {
        guard var summary = lastSummary, summary.hasProblems else { return }
        prune(&summary)
        guard summary != lastSummary else { return }
        lastSummary = summary.hasProblems ? summary : nil
        reportedProblemSignature = summary.problemSignature
    }

    /// Reihenfolge-Sperre (FIFO) auf dem MainActor: Beim Freigeben geht die
    /// Sperre direkt an den nächsten Wartenden über.
    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
