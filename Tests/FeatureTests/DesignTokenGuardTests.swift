import Foundation
import Testing

/// Schriftgrößen und Farben kommen in Features aus den Design-Tokens
/// (`AppTypography`, `AppPalette`), damit das Erscheinungsbild an einer
/// Stelle definiert ist. Berechnete Größen (z. B. Initialen im Bank-Logo)
/// sind erlaubt, feste Zahlen und eigene Farbwerte nicht.
@Suite("DesignTokenGuard")
struct DesignTokenGuardTests {
    private static var featuresDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FinanceTracker/Features", isDirectory: true)
    }

    private static func violations(matching pattern: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let files = FileManager.default.enumerator(at: featuresDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    hits.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        return hits
    }

    @Test("Keine festen Schriftgrößen in Features")
    func noFixedFontSizes() throws {
        let hits = try Self.violations(matching: #"\.font\(\.system\(size:\s*[0-9]"#)
        #expect(hits.isEmpty, "Feste Schriftgröße statt AppTypography: \(hits.joined(separator: ", "))")
    }

    @Test("Keine eigenen Farbwerte in Features")
    func noRawColors() throws {
        let hits = try Self.violations(matching: #"Color\((red|hex|white):|Color\(\.sRGB"#)
        #expect(hits.isEmpty, "Eigene Farbe statt AppPalette: \(hits.joined(separator: ", "))")
    }
}
