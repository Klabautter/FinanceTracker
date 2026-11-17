#if DEBUG
import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("CommandPaletteQuestion")
struct CommandPaletteQuestionTests {
    @Test("Frage in der Palette liefert eine Antwortzeile, Suchbegriff nicht")
    func answersQuestions() async throws {
        let dependencies = PreviewDependencies.dependencies()
        let defaults = UserDefaults(suiteName: "palette-\(UUID().uuidString)")!
        defaults.set(false, forKey: PrivacyPresentationState.defaultsKey)
        let model = CommandPaletteModel(dependencies: dependencies, privacyState: PrivacyPresentationState(defaults: defaults))
        await model.loadStaticEntries()

        #expect(await model.answer(question: "REWE") == nil)
        let answer = try #require(await model.answer(question: "Wie viel habe ich diesen Monat für Lebensmittel ausgegeben?"))
        #expect(answer.contains("Lebensmittel"))
        #expect(answer.contains("ausgegeben"))
        #expect(answer.contains("Buchungen"))
    }
}
#endif
