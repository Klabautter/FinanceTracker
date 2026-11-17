#if DEBUG && os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import FinanceTracker

/// Screenshot-Galerie mit Abnahme (Roadmap 5.8): Die Bereiche mit Tabellen
/// werden bei der Mindest- und einer üblichen Fensterbreite, hell und
/// dunkel, offscreen gerendert. Geprüft wird, dass keine Tabelle breiter
/// als ihr sichtbarer Bereich ist, also kein Betrag abgeschnitten wird oder
/// seitlich gescrollt werden muss. Die Bilder landen im temporären Ordner
/// (oder in `TEST_RUNNER_SCREEN_GALLERY_DIR`), um sie anzusehen.
@MainActor
@Suite("ScreenLayoutFit", .serialized)
struct ScreenLayoutFitTests {
    private static let sizes: [CGSize] = [CGSize(width: 840, height: 620), CGSize(width: 1_280, height: 800)]
    private static let sections: [AppSection] = [.transactions, .budgets, .recurring, .pockets]

    private var galleryDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["TEST_RUNNER_SCREEN_GALLERY_DIR"] ?? env["SCREEN_GALLERY_DIR"] {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("FinanceTrackerLayoutGallery", isDirectory: true)
    }

    @Test("Tabellen passen bei 840 und 1280 pt, hell und dunkel, ohne seitliches Scrollen")
    func tablesFitTheirWindow() async throws {
        let dependencies = PreviewDependencies.dependencies()
        let defaults = UserDefaults(suiteName: "LayoutFit-\(UUID().uuidString)")!
        defaults.set(false, forKey: PrivacyPresentationState.defaultsKey)
        let privacy = PrivacyPresentationState(defaults: defaults)
        try FileManager.default.createDirectory(at: galleryDirectory, withIntermediateDirectories: true)

        var overflows: [String] = []
        for scheme in [ColorScheme.light, .dark] {
            for size in Self.sizes {
                for section in Self.sections {
                    let name = "\(section.rawValue)-\(Int(size.width))-\(scheme == .dark ? "dark" : "light")"
                    let overflow = try await renderAndMeasure(
                        MacRootView(dependencies: dependencies, initialSection: section),
                        size: size, scheme: scheme, privacy: privacy, name: name
                    )
                    overflows += overflow.map { "\(name): \($0)" }
                }
            }
        }
        #expect(overflows.isEmpty, "Tabellen breiter als sichtbar: \(overflows.joined(separator: "; "))")
    }

    /// Rendert die Ansicht, speichert ein PNG und liefert jede Tabelle, deren
    /// Inhalt breiter ist als ihr sichtbarer Ausschnitt.
    private func renderAndMeasure<V: View>(
        _ view: V, size: CGSize, scheme: ColorScheme, privacy: PrivacyPresentationState, name: String
    ) async throws -> [String] {
        let hosting = NSHostingView(rootView: view
            .environment(privacy)
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }

        // Laden abwarten: bis eine Tabelle mit Zeilen erscheint (höchstens
        // etwa drei Sekunden); Leerzustände haben keine Tabelle.
        var tables: [NSTableView] = []
        for _ in 0..<30 {
            hosting.layoutSubtreeIfNeeded()
            tables = Self.tableViews(in: hosting)
            if tables.contains(where: { $0.numberOfRows > 0 }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        hosting.layoutSubtreeIfNeeded()

        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: galleryDirectory.appendingPathComponent("\(name).png"))
        }

        return tables.compactMap { table in
            guard let clip = table.enclosingScrollView?.contentView else { return nil }
            let contentWidth = table.tableColumns.filter { !$0.isHidden }.reduce(CGFloat(0)) { $0 + $1.width }
                + CGFloat(max(0, table.tableColumns.count - 1)) * table.intercellSpacing.width
            return contentWidth > clip.bounds.width + 1
                ? "Inhalt \(Int(contentWidth)) pt > sichtbar \(Int(clip.bounds.width)) pt"
                : nil
        }
    }

    private static func tableViews(in view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        if let table = view as? NSTableView { found.append(table) }
        for subview in view.subviews { found += tableViews(in: subview) }
        return found
    }
}
#endif
