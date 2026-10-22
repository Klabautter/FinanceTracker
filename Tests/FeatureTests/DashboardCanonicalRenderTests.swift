#if DEBUG && os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import FinanceTracker

/// Statische Renderprüfung des kanonischen Dashboards bei den im Audit
/// festgelegten Fensterbreiten. Dies ist kein UI-Durchklick-Test.
///
/// Über `TEST_RUNNER_FOCUS_RENDER_DIR` können PNGs für eine visuelle
/// Inspektion geschrieben werden.
@MainActor
@Suite("DashboardCanonicalRender")
struct DashboardCanonicalRenderTests {

    @Test("Kanonisches Dashboard rendert hell und dunkel an den geplanten Fenstermaßen")
    func rendersCanonicalDashboardAtPlannedWidths() async throws {
        let dependencies = PreviewDependencies.dependencies()
        let model = DashboardModel(dependencies: dependencies)
        await model.load()
        let snapshot = try #require(model.snapshot)
        let privacy = PrivacyPresentationState(defaults: scratchDefaults())

        let windowSizes: [(width: CGFloat, height: CGFloat)] = [
            (880, 620),
            (1_280, 800),
            (1_600, 1_000),
            (880, 2_200),
            (1_280, 2_200)
        ]
        for hidesAmounts in [false, true] {
        privacy.hidesAmounts = hidesAmounts
        for size in windowSizes {
            for colorScheme in [ColorScheme.light, .dark] {
                let content = ZStack(alignment: .topLeading) {
                    (colorScheme == .light ? Color.white : Color.black).ignoresSafeArea()
                    BentoDashboardContent(
                        model: model,
                        snapshot: snapshot,
                        onOpenCategory: { _ in },
                        onOpenReviewQueue: {},
                        onOpenTransaction: { _ in },
                        scrollsContent: false
                    )
                    .environment(privacy)
                }
                .environment(\.colorScheme, colorScheme)
                // The live dashboard is a scroll view whose initial position
                // is the top edge. Keep the static render anchored there too;
                // SwiftUI's default center alignment otherwise crops the
                // headline cards when the stack is taller than the viewport.
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()

                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let image = try #require(
                    renderer.nsImage,
                    "Dashboard bei \(size.width)×\(size.height) pt in \(colorScheme) rendert nicht"
                )
                #expect(image.size.width == size.width)
                #expect(image.size.height == size.height)

                let tiff = try #require(image.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: tiff))
                #expect(bitmap.pixelsWide == Int(size.width * 2))
                #expect(bitmap.pixelsHigh == Int(size.height * 2))
                #expect(
                    renderedPixelCount(in: bitmap, differingFrom: colorScheme == .light ? .white : .black) > 100,
                    "Dashboard-Inhalt fehlt im Render bei \(size.width)×\(size.height) pt in \(colorScheme)"
                )
                let privacySuffix = hidesAmounts ? "-privacy" : ""
                try write(image, named: "dashboard-\(Int(size.width))-\(Int(size.height))-\(colorScheme)\(privacySuffix)")
            }
        }
        }
    }

    private func write(_ image: NSImage, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_FOCUS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["FOCUS_RENDER_DIR"] else { return }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private func renderedPixelCount(in bitmap: NSBitmapImageRep, differingFrom background: NSColor) -> Int {
        var differingPixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard
                    let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    let base = background.usingColorSpace(.deviceRGB)
                else { continue }
                let distance = abs(pixel.redComponent - base.redComponent)
                    + abs(pixel.greenComponent - base.greenComponent)
                    + abs(pixel.blueComponent - base.blueComponent)
                if distance > 0.08 { differingPixels += 1 }
            }
        }
        return differingPixels
    }

    /// Der Test darf die echte Privacy-Einstellung des Nutzers weder lesen
    /// noch verändern.
    private func scratchDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "CanonicalRenderTests-\(UUID().uuidString)")!
        suite.set(false, forKey: PrivacyPresentationState.defaultsKey)
        return suite
    }
}
#endif
