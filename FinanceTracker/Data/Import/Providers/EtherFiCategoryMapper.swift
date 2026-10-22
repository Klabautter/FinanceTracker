import Foundation

/// Übersetzt die Branchenangabe aus dem ether.fi-Export (Händlerkategorie,
/// teils mit vorangestelltem MCC wie „5814 - …") in eine System-Kategorie.
///
/// Provider-Semantik bleibt hier in der Data-Schicht: Die
/// Pipeline bekommt nur eine neutrale Kategorie-ID als Vorschlag. Unbekannte
/// Branchen ergeben `nil`: Es gibt bewusst keinen „Sonstiges"-Fallback,
/// die Buchung landet dann in der Prüfliste.
enum EtherFiCategoryMapper {
    /// Reihenfolge = Priorität: spezifische Begriffe vor allgemeinen.
    private static let keywordMap: [(keywords: [String], category: Category)] = [
        (["grocery", "supermarket", "food stores", "convenience", "bakeries", "dairy", "candy"], .groceries),
        (["restaurant", "fast food", "eating places", "drinking places", "caterer"], .restaurants),
        (["drug store", "pharmac", "doctor", "dentist", "hospital", "medical", "optician", "optical"], .health),
        (["service station", "fuel", "gas station", "petroleum"], .fuel),
        (["taxi", "limousine"], .taxi),
        (["railroad", "railway", "bus line", "commuter", "passenger rail", "local transit", "transit"], .publicTransport),
        (["airline", "air carrier", "hotel", "lodging", "motel", "travel agenc", "car rental", "cruise"], .travel),
        (["utilities", "electric"], .utilities),
        (["subscription", "cable", "streaming", "telecommunication", "computer network"], .subscriptions),
        ([
            "clothing", "apparel", "electronics", "shoe", "department store", "book", "sporting goods",
            "bicycle", "digital goods", "furniture", "household", "variety store", "jewelry", "cosmetic",
            "toy", "hardware", "home supply", "discount store", "computer software", "record store", "gift"
        ], .shopping)
    ]

    static func categoryID(for providerCategory: String?) -> Category.ID? {
        guard let providerCategory else { return nil }
        let normalized = providerCategory
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        for entry in keywordMap where entry.keywords.contains(where: normalized.contains) {
            return entry.category.id
        }
        return nil
    }
}
