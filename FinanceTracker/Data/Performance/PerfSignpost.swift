import Foundation
import os

/// WP33 (§236): Performance-Signposts für Instruments, nur Namen und
/// Zähler, KEINE sensiblen Daten (Beträge/Händler bleiben draußen).
enum PerfSignpost {
    static let signposter = OSSignposter(
        subsystem: "de.klabautter.FinanceTracker",
        category: "performance"
    )

    /// Umschließt eine kritische Phase mit einem Signpost-Interval.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await body()
    }
}
