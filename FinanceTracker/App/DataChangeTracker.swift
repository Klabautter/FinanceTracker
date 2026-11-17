import Foundation

/// Zählt Datenänderungen, damit Ansichten nachladen. Lesen und Erhöhen nur
/// auf dem MainActor; dadurch ist der Tracker ohne `@unchecked` `Sendable`.
@MainActor
@Observable
final class DataChangeTracker {
    private(set) var revision = 0

    /// Darf überall erzeugt werden (die Abhängigkeiten entstehen beim Start
    /// abseits des MainActors); es wird nur der Startwert gesetzt.
    nonisolated init() {}

    func markChanged() {
        revision += 1
    }
}
