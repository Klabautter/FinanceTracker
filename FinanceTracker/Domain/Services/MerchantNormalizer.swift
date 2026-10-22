import Foundation

struct MerchantResolution: Sendable, Equatable {
    let displayName: String
    let merchantID: UUID?
    let newMerchant: Merchant?
    let merchantToUpsert: Merchant?
}

struct MerchantNormalizer: Sendable {
    struct Rule: Sendable {
        let keywords: [String]
        let canonicalName: String
    }

    static let builtinRules: [Rule] = [
        Rule(keywords: ["REWE"], canonicalName: "REWE"),
        Rule(keywords: ["BILLA"], canonicalName: "BILLA"),
        Rule(keywords: ["SPAR DANKT", "SPAR"], canonicalName: "SPAR"),
        Rule(keywords: ["LIDL"], canonicalName: "LIDL"),
        Rule(keywords: ["HOFER"], canonicalName: "HOFER"),
        Rule(keywords: ["AMZN", "AMAZON"], canonicalName: "Amazon"),
        Rule(keywords: ["SPOTIFY"], canonicalName: "Spotify"),
        Rule(keywords: ["NETFLIX"], canonicalName: "Netflix"),
        Rule(keywords: ["SHELL"], canonicalName: "Shell"),
        Rule(keywords: ["WIENER LINIEN"], canonicalName: "Wiener Linien"),
        Rule(keywords: ["APPLE.COM", "APPLE", "ITUNES"], canonicalName: "Apple"),
        Rule(keywords: ["DM DROGERIE", "DM"], canonicalName: "dm"),
        Rule(keywords: ["MCDONALDS", "MCDONALD'S", "MCDONALD"], canonicalName: "McDonald's"),
        Rule(keywords: ["UBER"], canonicalName: "Uber"),
        Rule(keywords: ["BOLT"], canonicalName: "Bolt"),
        Rule(keywords: ["ZALANDO"], canonicalName: "Zalando"),
        Rule(keywords: ["MEDIAMARKT", "MEDIA MARKT"], canonicalName: "MediaMarkt"),
        Rule(keywords: ["ADOBE"], canonicalName: "Adobe"),
        Rule(keywords: ["MAGENTA TELEKOM"], canonicalName: "Magenta Telekom"),
        Rule(keywords: ["WIEN ENERGIE"], canonicalName: "Wien Energie"),
        Rule(keywords: ["VAPIANO"], canonicalName: "Vapiano"),
        Rule(keywords: ["FITINN"], canonicalName: "Fitinn"),
        Rule(keywords: ["OEBB", "ÖBB"], canonicalName: "ÖBB"),
        Rule(keywords: ["OMV"], canonicalName: "OMV"),
        Rule(keywords: ["BANKOMAT"], canonicalName: "Bankomat"),
        Rule(keywords: ["APOTHEKE"], canonicalName: "Shop Apotheke"),
        Rule(keywords: ["INSTANT GAMING"], canonicalName: "Instant Gaming"),
        Rule(keywords: ["SHOKZ"], canonicalName: "Shokz")
    ]

    private let rules: [Rule]

    static let maxFallbackWords = 4

    static let legalFormTokens: Set<String> = [
        "GMBH", "MBH", "AG", "KG", "KGAA", "SE", "UG", "OHG", "EV", "CO", "COKG",
        "SCA", "SARL", "SA", "SAS", "SRL", "SPA", "LTD", "LIMITED", "INC", "LLC", "PLC",
        "BV", "NV", "AB", "AS", "OY", "ET", "CIE"
    ]

    /// „S.à r.l.," → „SARL": Punkte, Kommas und Akzente zählen nicht.
    static func legalFormKey(_ token: String) -> String {
        token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .uppercased()
            .filter { $0.isLetter }
    }

    init(rules: [Rule] = MerchantNormalizer.builtinRules) {
        self.rules = rules
    }

    func normalizedKey(_ input: String) -> String {
        CategoryRuleEngine.normalizedKey(input)
    }

    func canonicalDisplayName(from rawDescriptor: String?) -> String? {
        guard var cleaned = rawDescriptor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else { return nil }

        let key = normalizedKey(cleaned)
        guard !key.isEmpty else { return nil }

        for rule in rules {
            for keyword in rule.keywords {
                if CategoryRuleEngine.containsTokenSequence(key, normalizedKey(keyword)) {
                    return rule.canonicalName
                }
            }
        }

        let tokens = cleaned
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        // Ohne Filialnummern, Einzelzeichen und Rechtsformen („GmbH",
        // „S.C.A"), sonst bliebe von „urban - homes for students GmbH" nur
        // „urban homes for" übrig.
        let meaningful = tokens.filter { token in
            token.rangeOfCharacter(from: .decimalDigits) == nil
                && token.count >= 2
                && !Self.legalFormTokens.contains(Self.legalFormKey(token))
        }
        if !meaningful.isEmpty {
            cleaned = meaningful.prefix(Self.maxFallbackWords).joined(separator: " ")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cleaned
    }

    func resolve(
        rawDescriptor: String?,
        knownMerchants: [Merchant]
    ) -> MerchantResolution {
        guard let rawDescriptor,
              let displayName = canonicalDisplayName(from: rawDescriptor) else {
            let fallback = rawDescriptor?.trimmingCharacters(in: .whitespacesAndNewlines)
            return MerchantResolution(
                displayName: (fallback?.isEmpty == false) ? fallback! : "Unbekannt",
                merchantID: nil,
                newMerchant: nil,
                merchantToUpsert: nil
            )
        }

        let descriptorKey = normalizedKey(rawDescriptor)
        let displayKey = normalizedKey(displayName)

        for merchant in knownMerchants {
            let candidates = [merchant.displayName] + merchant.aliases
            for candidate in candidates {
                let candidateKey = normalizedKey(candidate)
                guard !candidateKey.isEmpty else { continue }

                if CategoryRuleEngine.containsTokenSequence(descriptorKey, candidateKey)
                    || displayKey == candidateKey {
                    var updatedMerchant = merchant
                    let alreadyKnown = candidates.contains {
                        normalizedKey($0) == descriptorKey
                    }
                    if !alreadyKnown {
                        updatedMerchant.aliases.append(rawDescriptor.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    return MerchantResolution(
                        displayName: merchant.displayName,
                        merchantID: merchant.id,
                        newMerchant: nil,
                        merchantToUpsert: alreadyKnown ? nil : updatedMerchant
                    )
                }
            }
        }

        let trimmedDescriptor = rawDescriptor.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = descriptorKey == displayKey ? [] : [trimmedDescriptor]
        let newMerchant = Merchant(displayName: displayName, aliases: aliases)
        return MerchantResolution(
            displayName: displayName,
            merchantID: newMerchant.id,
            newMerchant: newMerchant,
            merchantToUpsert: newMerchant
        )
    }
}
