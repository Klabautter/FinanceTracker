import Foundation

/// Merkt sich die Bankliste je Anbieter und Land für die Laufzeit der App.
/// Die Liste ändert sich selten, ist aber groß (Deutschland: mehrere tausend
/// Institute), so lädt sie beim zweiten Öffnen des Dialogs sofort.
actor BankInstitutionCache {
    private struct Entry {
        let loadedAt: Date
        let institutions: [BankInstitution]
    }

    private let lifetime: TimeInterval
    private var entries: [String: Entry] = [:]

    init(lifetime: TimeInterval = 6 * 60 * 60) {
        self.lifetime = lifetime
    }

    func institutions(provider: String, country: String, now: Date = Date()) -> [BankInstitution]? {
        guard let entry = entries[Self.key(provider, country)],
              now.timeIntervalSince(entry.loadedAt) < lifetime else { return nil }
        return entry.institutions
    }

    func store(_ institutions: [BankInstitution], provider: String, country: String, now: Date = Date()) {
        entries[Self.key(provider, country)] = Entry(loadedAt: now, institutions: institutions)
    }

    private static func key(_ provider: String, _ country: String) -> String {
        "\(provider)|\(country.uppercased())"
    }
}
