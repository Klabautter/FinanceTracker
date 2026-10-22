import Foundation
import Testing

@testable import FinanceTracker

@Suite("MerchantKeywordCategorizer")
struct MerchantKeywordCategorizerTests {
    private func txn(_ merchant: String, amount: Decimal = -10, kind: TransactionKind = .purchase) -> Transaction {
        Transaction(
            accountID: UUID(),
            source: .genericCSV,
            kind: kind,
            amount: Money(amount: amount, currency: .eur),
            bookedAt: Date(),
            rawDescription: merchant,
            rawMerchantName: merchant,
            merchantDisplayName: merchant
        )
    }

    @Test("Branchenwörter im Händlernamen ergeben die Kategorie")
    func readsCategoryFromName() {
        let cases: [(String, FinanceTracker.Category)] = [
            ("GINZA SUSHI", .restaurants),
            ("Ali's Gemüsekebap", .restaurants),
            ("Der Landgasthof Gut Winkel", .restaurants),
            ("TH SYSTEMGASTRONOMIE GmbH", .restaurants),
            ("BAECKEREI MUSTER GMBH", .groceries),
            ("Bäckerei Beispiel Filiale 3", .groceries),
            ("EUROSPAR BZ", .groceries),
            ("GASOMETER APOTHEKE", .health),
            ("Stadtapotheke am Markt", .health),
            ("PEARLE OPTIK WIEN", .health),
            ("TANKSTELLE RAN-STATION", .fuel),
            ("westbahn.at", .publicTransport),
            ("WIENER L 20261008016530", .publicTransport),
            ("HOTEL POST", .travel),
            ("RYANAIR", .travel),
            ("OPENAI *CHATGPT SUBSCR", .subscriptions),
            ("DECATHLON Deutschland SE", .shopping),
            ("Hornbach Baumarkt AG", .shopping),
            ("Vorabpauschale for ISIN XX0000000001", .investments),
            ("CARLS JR. SLAGELSE 1963", .restaurants),
            ("KVARNRESTAURANGEN", .restaurants),
            ("La Pioppa Ovest Mychef", .restaurants),
            ("Dahls Bager-10", .groceries),
            ("denn s Wien Landstr.209", .groceries),
            ("SUPERMERCATI POLI", .groceries),
            ("FUNIVIE MONTE BALDO", .travel),
            ("RADHAUS INGOLSTADT", .shopping),
            ("Philips Consumer Lifestyle", .shopping),
            ("Uni Wien Studienbeitrag", .other),
            ("WWW.AKADEMIKERHILFE.AT", .rent),
            ("Wien Energie Vertrieb", .utilities)
        ]
        for (name, expected) in cases {
            #expect(MerchantKeywordCategorizer.categoryID(for: txn(name)) == expected.id, "\(name)")
        }
    }

    @Test("Namen ohne Branchenwort bleiben offen, kein Sonstiges-Fallback")
    func leavesUnknownNamesOpen() {
        for name in ["Mol*Ravis GmbH", "Barkes Audimax", "BERTOZZI MARCO", "MBA", "Müller", "Merkur", ""] {
            #expect(MerchantKeywordCategorizer.categoryID(for: txn(name)) == nil, "\(name)")
        }
        // Wortgrenzen: „Bahnhofskiosk" ist keine Bahn, „Claude Dupont" kein Abo.
        #expect(MerchantKeywordCategorizer.categoryID(for: txn("Bahnhofskiosk")) == nil)
        #expect(MerchantKeywordCategorizer.categoryID(for: txn("Claude Dupont")) == nil)
    }

    @Test("Ausgaben- und Einnahme-Wörter gelten nur für ihre Richtung; Umbuchungen nie")
    func respectsDirection() {
        #expect(MerchantKeywordCategorizer.categoryID(for: txn("Your interest payment", amount: 8)) == Category.income.id)
        #expect(MerchantKeywordCategorizer.categoryID(for: txn("Cash Dividend for ISIN XX", amount: 2)) == Category.income.id)
        #expect(MerchantKeywordCategorizer.categoryID(for: txn("Interest charge", amount: -8)) == nil)
        // Eine Gutschrift vom Restaurant ist keine Restaurant-Ausgabe.
        #expect(MerchantKeywordCategorizer.categoryID(for: txn("GINZA SUSHI", amount: 12)) == nil)
        #expect(MerchantKeywordCategorizer.categoryID(for: txn("HOTEL POST", kind: .transfer)) == nil)
    }

    @Test("Der ungekürzte Händlertext zählt mit, wenn der Anzeigename ihn verkürzt")
    func readsRawMerchantText() {
        let shortened = Transaction(
            accountID: UUID(),
            source: .genericCSV,
            kind: .purchase,
            amount: Money(amount: -467, currency: .eur),
            bookedAt: Date(),
            rawDescription: "WIENER L 20261008016530",
            rawMerchantName: nil,
            merchantDisplayName: "WIENER"
        )
        #expect(MerchantKeywordCategorizer.categoryID(for: shortened) == FinanceTracker.Category.publicTransport.id)

        // Mit eigenem Händlernamen bleibt der freie Verwendungszweck außen vor.
        let transfer = Transaction(
            accountID: UUID(),
            source: .openBanking,
            kind: .purchase,
            amount: Money(amount: -30, currency: .eur),
            bookedAt: Date(),
            rawDescription: "Danke fuers Restaurant gestern",
            rawMerchantName: "Erika Musterfrau",
            merchantDisplayName: "Erika Musterfrau"
        )
        #expect(MerchantKeywordCategorizer.categoryID(for: transfer) == nil)
    }

    @Test("Wertpapier-Nebenbuchungen gehören in beiden Richtungen zur Geldanlage")
    func investmentsBothDirections() {
        #expect(MerchantKeywordCategorizer.categoryID(for: txn("Tax Optimisation", amount: 15)) == FinanceTracker.Category.investments.id)
        #expect(MerchantKeywordCategorizer.categoryID(for: txn("Tax Optimisation", amount: -1)) == FinanceTracker.Category.investments.id)
    }

    @Test("Regeln haben Vorrang; das Branchenwort ist nur die letzte Stufe")
    func rulesWinOverKeywords() {
        let userRule = CategoryRule(priority: 1, condition: .merchantContains("SUSHI"), categoryID: Category.groceries.id)
        let compiled = CategoryRuleEngine().compile([userRule])
        var withRule = txn("GINZA SUSHI")
        #expect(compiled.apply(to: &withRule))
        #expect(withRule.categoryID == Category.groceries.id)

        var keywordOnly = txn("TRATTORIA BEISPIEL")
        #expect(compiled.apply(to: &keywordOnly))
        #expect(keywordOnly.categoryID == Category.restaurants.id)

        // Nicht (mehr) zuweisbare Kategorien werden nicht vergeben.
        let restricted = CategoryRuleEngine().compile([], assignableCategoryIDs: [Category.groceries.id])
        var blocked = txn("TRATTORIA BEISPIEL")
        #expect(!restricted.apply(to: &blocked))
        #expect(blocked.categoryID == nil)
    }
}
