import Foundation
import Testing

@testable import FinanceTracker

@Suite("Bankauswahl")
struct BankInstitutionSearchTests {
    private func bank(_ name: String, _ country: String = "DE") -> BankInstitution {
        BankInstitution(id: "\(country)|\(name)", name: name, bic: nil, transactionTotalDays: nil)
    }

    private var germanBanks: [BankInstitution] {
        [
            "Commerzbank", "DKB", "Deutsche Bank", "ING", "Ingolstädter Sparkasse",
            "Sparkasse Göttingen", "Sparkasse Tübingen", "Volksbank Sigmaringen",
            "Kreissparkasse Köln", "N26", "Raiffeisenbank Oberland", "Sparkasse Allgäu",
            "Sparkasse KölnBonn", "VR Bank Musterstadt", "Volksbank Mittelhessen"
        ].sorted().map { bank($0) }
    }

    @Test("Ganzes Wort vor Wortanfang: „ING“ findet zuerst ING, nicht Ingolstadt")
    func exactWordRanksFirst() {
        let result = BankInstitutionSearch.search("ing", in: germanBanks)
        #expect(result.matches.first?.name == "ING")
        #expect(result.matches.map(\.name).contains("Ingolstädter Sparkasse"))
    }

    @Test("Akzente und Groß-/Kleinschreibung zählen nicht")
    func foldsDiacritics() {
        let result = BankInstitutionSearch.search("koln", in: germanBanks)
        #expect(Set(result.matches.map(\.name)) == ["Kreissparkasse Köln", "Sparkasse KölnBonn"])
    }

    @Test("Teil eines Wortes wird gefunden")
    func findsInnerSubstring() {
        let result = BankInstitutionSearch.search("sparkasse", in: germanBanks)
        #expect(result.matches.count == 6)
        // „Sparkasse Allgäu“ (ganzes Wort) vor „Kreissparkasse Köln“ (Wortinneres)
        #expect(result.matches.first?.name == "Sparkasse Allgäu")
        #expect(result.matches.last?.name == "Kreissparkasse Köln")
    }

    @Test("Lange Trefferlisten werden gekürzt und zählen den Rest")
    func limitsResults() {
        let many = (1...120).map { bank("Sparkasse Nr \($0)") }
        let result = BankInstitutionSearch.search("sparkasse", in: many, limit: 50)
        #expect(result.matches.count == 50)
        #expect(result.totalCount == 120)
        #expect(result.hiddenCount == 70)
    }

    @Test("Leere Suche liefert nichts statt aller Banken")
    func emptyQuery() {
        #expect(BankInstitutionSearch.search("   ", in: germanBanks).matches.isEmpty)
    }

    @Test("Beliebte Banken: je Stichwort ein Treffer, in fester Reihenfolge")
    func popularBanks() {
        let popular = BankInstitutionSearch.popular(in: germanBanks, country: "DE").map(\.name)
        #expect(Array(popular.prefix(3)) == ["DKB", "ING", "Volksbank Mittelhessen"])
        #expect(popular.contains("N26"))
        #expect(Set(popular).count == popular.count)
    }

    @Test("„ING“ in Ortsnamen macht ING nicht zur Bankengruppe")
    func placeNamesDoNotMakeGroups() {
        #expect(BankInstitutionSearch.popular(in: germanBanks, country: "DE").first { $0.name == "ING" } != nil)
        #expect(!BankInstitutionSearch.groupShortcuts(in: germanBanks, country: "DE").contains("ING"))
    }

    @Test("Bankengruppen wie die Sparkasse werden zur Suche statt zu einer zufälligen Filiale")
    func groupsBecomeShortcuts() {
        let popular = BankInstitutionSearch.popular(in: germanBanks, country: "DE").map(\.name)
        #expect(!popular.contains { $0.contains("Sparkasse") })
        #expect(BankInstitutionSearch.groupShortcuts(in: germanBanks, country: "DE") == ["Sparkasse"])
    }

    @Test("Land ohne Liste beliebter Banken liefert keine Vorschläge")
    func popularUnknownCountry() {
        #expect(BankInstitutionSearch.popular(in: [bank("Swedbank", "SE")], country: "SE").isEmpty)
    }
}

@Suite("Bankliste-Zwischenspeicher")
struct BankInstitutionCacheTests {
    @Test("Liefert die Liste je Anbieter und Land, bis sie veraltet")
    func expires() async {
        let cache = BankInstitutionCache(lifetime: 60)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let list = [BankInstitution(id: "DE|DKB", name: "DKB", bic: nil, transactionTotalDays: nil)]
        await cache.store(list, provider: "enablebanking", country: "de", now: start)

        #expect(await cache.institutions(provider: "enablebanking", country: "DE", now: start.addingTimeInterval(30)) == list)
        #expect(await cache.institutions(provider: "enablebanking", country: "AT", now: start) == nil)
        #expect(await cache.institutions(provider: "gocardless", country: "DE", now: start) == nil)
        #expect(await cache.institutions(provider: "enablebanking", country: "DE", now: start.addingTimeInterval(61)) == nil)
    }
}

@MainActor
@Suite("Eine Bankverbindung trennen")
struct BankConnectDisconnectTests {
    private func connection(_ institution: String) -> Connection {
        let now = Date()
        return Connection(
            id: UUID(), userID: UUID(), provider: .enablebanking,
            providerConnectionID: "session-\(institution)", institutionID: "DE|\(institution)",
            status: .active, consentExpiresAt: nil, lastSuccessfulSyncAt: nil,
            createdAt: now, updatedAt: now
        )
    }

    @Test("Trennt nur die gewählte Bank; Konten bleiben, Schlüssel und andere Banken unberührt")
    func disconnectsOnlyOneBank() async throws {
        let store = try SwiftDataStore(inMemory: true)
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let credentials = InMemoryEnableBankingCredentialStore(applicationID: "app", privateKeyPEM: "pem")
        let dkb = connection("DKB")
        let vr = connection("VR Bank")
        try await dependencies.connectionRepository.upsert([dkb, vr])
        let dkbAccount = Account(connectionID: dkb.id, name: "DKB", type: .checking, currency: .eur, source: .openBanking)
        let vrAccount = Account(connectionID: vr.id, name: "VR", type: .checking, currency: .eur, source: .openBanking)
        try await dependencies.accountRepository.upsert([dkbAccount, vrAccount])

        let model = BankConnectModel(dependencies: dependencies, enableBankingCredentialStore: credentials)
        await model.loadConnections()
        #expect(model.banksUsingCredentials.count == 2)

        await model.disconnect(dkb)

        let remaining = try await dependencies.connectionRepository.connections()
        #expect(remaining.map(\.id) == [vr.id])
        let accounts = try await dependencies.accountRepository.accounts()
        let keptDKB = try #require(accounts.first { $0.id == dkbAccount.id })
        #expect(keptDKB.isActive == false)
        #expect(keptDKB.connectionID == nil)
        #expect(accounts.first { $0.id == vrAccount.id }?.connectionID == vr.id)
        #expect(credentials.readApplicationID() == "app")
        #expect(model.connections.map(\.id) == [vr.id])
    }
}
