import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Verdrahtung des Frage-Verstehers: das Sprachmodell des Geräts, wo es
/// eines gibt, sonst keiner (Fragen laufen dann nur über die festen Regeln).
enum FinanceQuestionInterpreterFactory {
    static func systemInterpreter() -> (any FinanceQuestionInterpreter)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return AppleIntelligenceQuestionInterpreter()
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
/// Fragt das Sprachmodell von Apple Intelligence, welche vorhandene
/// Kategorie eine frei formulierte Frage meint. Es läuft auf dem Gerät:
/// Die Frage und die Kategorienamen verlassen es nicht, und es werden
/// keine Buchungen, Beträge oder Kontodaten übergeben. Das Modell kann nur
/// einen der vorhandenen Namen oder „keine" antworten, nichts erfinden.
@available(macOS 26.0, iOS 26.0, *)
struct AppleIntelligenceQuestionInterpreter: FinanceQuestionInterpreter {
    private static let none = "Keine davon"

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    func categoryName(inQuestion question: String, categoryNames: [String]) async -> String? {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = Array(Set(categoryNames)).filter { $0 != Self.none }.sorted()
        guard isAvailable, !text.isEmpty, !names.isEmpty else { return nil }
        do {
            let schema = try GenerationSchema(
                root: DynamicGenerationSchema(name: "Kategorie", anyOf: names + [Self.none]),
                dependencies: []
            )
            let session = LanguageModelSession(instructions: """
                Du bekommst eine Frage zu den eigenen Ausgaben oder Einnahmen, auf Deutsch \
                oder Englisch. Entscheide, nach welcher Haushaltskategorie gefragt wird.

                Vorhandene Kategorien:
                \(names.map { "- \($0)" }.joined(separator: "\n"))

                Wähle die Kategorie, die inhaltlich gemeint ist, auch wenn die Frage ein \
                anderes Wort dafür benutzt (zum Beispiel „Essen gehen“ für Restaurants oder \
                „Sprit“ für Tanken). Fragt die Frage nach keiner bestimmten Art von Ausgabe, \
                nach einem Händler oder nach allem zusammen, wähle „\(Self.none)“.
                """)
            let choice = try await session.respond(
                to: text,
                schema: schema,
                options: Self.greedyOptions
            ).content.value(String.self)
            return names.contains(choice) ? choice : nil
        } catch {
            // Keine Zuordnung ist ein gültiges Ergebnis (Modell beschäftigt,
            // Sprache nicht unterstützt, Antwort nicht lesbar).
            return nil
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
private extension AppleIntelligenceQuestionInterpreter {
    /// Deterministische Antworten. Das Argument heißt ab dem SDK mit Swift
    /// 6.4 `samplingMode:`, davor `sampling:` (CI baut mit älterem Xcode).
    static var greedyOptions: GenerationOptions {
        #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy)
        #else
        GenerationOptions(sampling: .greedy)
        #endif
    }
}
#endif
