import Foundation
import Testing

@testable import FinanceTracker

/// Roadmap 2.3: Dateien, die aufs Fenster oder Dock-Symbol gezogen werden.
@MainActor
@Suite("ImportFileInbox")
struct ImportFileInboxTests {
    @Test("Nimmt nur Dateien an, die der Import lesen kann")
    func acceptsOnlyImportFiles() {
        let inbox = ImportFileInbox()
        #expect(inbox.offer(URL(fileURLWithPath: "/tmp/Umsaetze.CSV")))
        #expect(inbox.pending?.url.lastPathComponent == "Umsaetze.CSV")

        #expect(inbox.offer(URL(fileURLWithPath: "/tmp/foto.png")) == false)
        #expect(inbox.offer(URL(string: "https://example.com/a.csv")!) == false)
        // Die zuvor angenommene Datei wartet weiter.
        #expect(inbox.pending?.url.lastPathComponent == "Umsaetze.CSV")
    }

    @Test("Aus mehreren gezogenen Dateien zählt die erste lesbare; herausgenommen ist sie weg")
    func takesFirstReadableOnce() {
        let inbox = ImportFileInbox()
        let offered = inbox.offer(firstOf: [
            URL(fileURLWithPath: "/tmp/bild.heic"),
            URL(fileURLWithPath: "/tmp/auszug.pdf"),
            URL(fileURLWithPath: "/tmp/export.xlsx")
        ])
        #expect(offered)
        #expect(inbox.take()?.url.lastPathComponent == "auszug.pdf")
        #expect(inbox.take() == nil)
        #expect(inbox.offer(firstOf: [URL(fileURLWithPath: "/tmp/bild.heic")]) == false)
    }

    @Test("Dieselbe Datei kann zweimal hintereinander ankommen")
    func sameFileTwice() {
        let inbox = ImportFileInbox()
        let url = URL(fileURLWithPath: "/tmp/export.csv")
        inbox.offer(url)
        let first = inbox.take()
        inbox.offer(url)
        let second = inbox.take()
        #expect(first?.url == second?.url)
        #expect(first?.id != second?.id)
    }
}
