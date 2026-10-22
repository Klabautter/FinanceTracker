import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Verdrahtung des Kategorie-Beraters: das Sprachmodell des Geräts, wo es
/// eines gibt, sonst keiner (die Prüfliste bleibt dann ohne diese
/// Vorschläge voll nutzbar).
enum MerchantCategoryAdvisorFactory {
    static func systemAdvisor() -> (any MerchantCategoryAdvisor)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return AppleIntelligenceCategoryAdvisor()
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
/// Fragt das Sprachmodell von Apple Intelligence. Es läuft auf dem Gerät:
/// Händlername und Kategorienamen verlassen es nicht, und es werden keine
/// Beträge, Kontodaten oder Verwendungszwecke übergeben.
@available(macOS 26.0, iOS 26.0, *)
struct AppleIntelligenceCategoryAdvisor: MerchantCategoryAdvisor {
    /// Ausweg für das Modell, damit es bei nichtssagenden Namen nicht rät.
    private static let undecided = "Unklar"

    /// Kurzbeschreibungen der Standardkategorien, damit das Modell z. B.
    /// „Miete" nicht für jedes Wort mit „Home" wählt. Eigene Kategorien des
    /// Nutzers gehen nur mit ihrem Namen ein.
    private static let hints: [Category.ID: String] = [
        Category.groceries.id: "Supermärkte, Bäckereien, Metzgereien, Lebensmittelgeschäfte",
        Category.restaurants.id: "Restaurants, Cafés, Fast Food, Bars, Eisdielen, Lieferdienste",
        Category.fuel.id: "Tankstellen, Kraftstoff",
        Category.publicTransport.id: "Bahn, Bus, Nahverkehr, Fahrkarten",
        Category.taxi.id: "Taxi und Fahrdienste",
        Category.shopping.id: "Kleidung, Elektronik, Möbel, Sport, Bücher, Online-Shops, Markenhersteller",
        Category.subscriptions.id: "Software, Streaming, Apps, Mobilfunk, wiederkehrende Mitgliedschaften",
        Category.travel.id: "Hotels, Unterkünfte, Flüge, Mietwagen, Seilbahnen, Ausflüge",
        Category.rent.id: "nur die Wohnungsmiete an Vermieter oder Hausverwaltung",
        Category.utilities.id: "Strom, Gas, Wasser, Heizung, Internetanschluss",
        Category.health.id: "Apotheken, Ärzte, Optiker, Drogerien",
        Category.cash.id: "Abhebungen am Geldautomaten",
        Category.other.id: "nur für Einzelfälle wie Behördengebühren, für die sich keine eigene Kategorie lohnt"
    ]

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Eigene Antwort für „keine vorhandene Kategorie passt“.
    private static let needsNewCategory = "Neue Kategorie nötig"
    private static let noParent = "Keine"

    func adviseCategory(
        merchantName: String,
        isIncome: Bool,
        candidates: [Category],
        parents: [Category]
    ) async -> MerchantCategoryAdvice? {
        let name = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, !name.isEmpty, !candidates.isEmpty else { return nil }

        var categoryIDsByName: [String: Category.ID] = [:]
        // „Sonstiges“ bleibt dem Nutzer vorbehalten: Als Auffang würde das
        // Modell es sonst für alles wählen, was keine eigene Kategorie hat.
        for category in candidates
        where category.id != Category.other.id && ![Self.undecided, Self.needsNewCategory].contains(category.name) {
            categoryIDsByName[category.name] = categoryIDsByName[category.name] ?? category.id
        }
        let names = categoryIDsByName.keys.sorted()
        let overview = names
            .map { name in
                let hint = categoryIDsByName[name].flatMap { Self.hints[$0] }
                return hint.map { "- \(name): \($0)" } ?? "- \(name)"
            }
            .joined(separator: "\n")

        do {
            // Schritt 1: vorhandene Kategorie, „neue nötig“ oder „unklar“.
            let choiceSchema = try GenerationSchema(
                root: DynamicGenerationSchema(name: "Kategorie", anyOf: names + [Self.needsNewCategory, Self.undecided]),
                dependencies: []
            )
            let session = LanguageModelSession(instructions: """
                Du ordnest Kontobuchungen einer Haushaltskategorie zu. Du bekommst den Namen \
                eines Händlers, wie er auf einem Kontoauszug steht: oft gekürzt, in \
                Großbuchstaben, mit Ort oder Filialnummer, auch in anderen Sprachen. Nutze \
                dein Wissen über bekannte Marken, Ketten, Versicherungen, Behörden und \
                Branchenwörter im Namen.

                Vorhandene Kategorien:
                \(overview)

                Wähle eine vorhandene Kategorie, wenn sie inhaltlich passt. Erkennst du die Art \
                des Geschäfts (zum Beispiel eine Versicherung, Krankenkasse, Behörde, Steuer, \
                einen Verein oder eine Hilfsorganisation), aber keine vorhandene Kategorie passt \
                inhaltlich, wähle „\(Self.needsNewCategory)“. Wähle „\(Self.undecided)“ bei \
                Personennamen, Abkürzungen und Fantasienamen, deren Branche du nicht kennst.
                """)
            let direction = isIncome ? "Zahlungseingang von" : "Zahlung an"
            let choice = try await session.respond(
                to: "\(direction): \(name)",
                schema: choiceSchema,
                options: Self.greedyOptions
            ).content.value(String.self)

            if let categoryID = categoryIDsByName[choice] {
                return .existing(categoryID)
            }
            guard choice == Self.needsNewCategory else { return nil }

            // Schritt 2: Name und Einordnung der neuen Kategorie, ein
            // allgemeiner Oberbegriff, kein Händlername.
            let parentNames = parents.map(\.name).sorted()
            let proposalSchema = try GenerationSchema(
                root: DynamicGenerationSchema(name: "NeueKategorie", properties: [
                    .init(
                        name: "name",
                        description: "Allgemeiner deutscher Oberbegriff für diese Art von Ausgabe, ein bis zwei Wörter. Nie der Händlername und nie der Name einer vorhandenen Kategorie.",
                        schema: DynamicGenerationSchema(type: String.self)
                    ),
                    .init(
                        name: "hinweis",
                        description: "Das Wort aus dem Händlernamen, an dem man die Branche erkennt, genau so wie es im Namen steht.",
                        schema: DynamicGenerationSchema(type: String.self)
                    ),
                    .init(
                        name: "oberkategorie",
                        description: "Passende vorhandene Hauptkategorie oder „\(Self.noParent)“.",
                        schema: DynamicGenerationSchema(name: "Oberkategorie", anyOf: parentNames + [Self.noParent])
                    )
                ]),
                dependencies: []
            )
            let proposal = try await session.respond(
                to: "Schlage für „\(name)“ eine neue Kategorie vor.",
                schema: proposalSchema,
                options: Self.greedyOptions
            ).content
            let proposedName = try proposal.value(String.self, forProperty: "name")
            let parentName = try proposal.value(String.self, forProperty: "oberkategorie")
            let evidence = try proposal.value(String.self, forProperty: "hinweis")
            // Nur mit Beleg im Namen: Das Modell erfindet sonst Branchen für
            // Namen, die keine verraten.
            guard NewCategoryProposalPolicy.isGrounded(evidence: evidence, in: name),
                  let cleaned = NewCategoryProposalPolicy.cleanedName(proposedName, merchantName: name) else { return nil }
            // Gibt es die Kategorie schon (z. B. anders geschrieben), wird sie
            // genommen; wiederholt der Vorschlag nur eine Gruppe wie
            // „Mobilität“, ist er keine neue Kategorie.
            if let existing = NewCategoryProposalPolicy.existingMatch(for: cleaned, in: candidates) {
                return .existing(existing.id)
            }
            if NewCategoryProposalPolicy.existingMatch(for: cleaned, in: parents) != nil
                || NewCategoryProposalPolicy.overlapsExisting(cleaned, in: parents + candidates) {
                return nil
            }
            return .newCategory(name: cleaned, parentID: parents.first { $0.name == parentName }?.id)
        } catch {
            // Kein Vorschlag ist ein gültiges Ergebnis (Modell beschäftigt,
            // Sprache nicht unterstützt, Antwort nicht lesbar).
            return nil
        }
    }
}
#endif

@available(macOS 26.0, iOS 26.0, *)
private extension AppleIntelligenceCategoryAdvisor {
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
