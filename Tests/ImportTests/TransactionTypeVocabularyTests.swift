import Foundation
import Testing

@testable import FinanceTracker

@Suite("TransactionTypeVocabulary")
struct TransactionTypeVocabularyTests {
    @Test("Deutsche und englische Buchungsarten aus echten Exporten")
    func knownTypes() {
        let expected: [String: TransactionTypeMeaning] = [
            "Card purchase": .expense, "card_spend": .expense, "Kartenzahlung": .expense,
            "SEPA-Lastschrift": .expense, "Sparplan": .expense, "Savings plan execution": .expense, "Buy": .expense,
            "Sell trade": .income, "Verkauf": .income, "Interest payment": .income, "Zinsen": .income,
            "Dividende": .income, "Gehalt": .income,
            "Receive": .transfer, "Einzahlung": .transfer, "Top up": .transfer, "Aufladung": .transfer,
            "Currency exchange": .transfer, "Umbuchung": .transfer,
            "Card cashback": .cashback, "Saveback": .cashback, "reward": .cashback,
            "Refund": .refund, "card_refund": .refund, "Erstattung": .refund,
            "Fee": .fee, "Gebühr": .fee, "Kontoführungsgebühr": .fee, "gas_fee": .fee,
            "Steuern": .fee, "Ertrag": .income, "Empfehlung": .cashback
        ]
        for (raw, meaning) in expected {
            #expect(TransactionTypeVocabulary.meaning(of: raw) == meaning, "\(raw)")
        }
    }

    @Test("Mehrdeutiges und Unbekanntes wird nicht geraten")
    func ambiguousTypes() {
        for raw in ["Überweisung", "Transfer", "Withdrawal", "Bonus", "Mystery", "", "  "] {
            #expect(TransactionTypeVocabulary.meaning(of: raw) == nil, "\(raw)")
        }
        #expect(TransactionTypeVocabulary.meaning(of: nil) == nil)
    }

    @Test("Spezifisches vor Allgemeinem: Cashback und Erstattung zu Kartenzahlungen")
    func priority() {
        #expect(TransactionTypeVocabulary.meaning(of: "Card cashback") == .cashback)
        #expect(TransactionTypeVocabulary.meaning(of: "Card payment refund") == .refund)
        #expect(TransactionTypeVocabulary.meaning(of: "Card fee") == .fee)
        #expect(TransactionTypeVocabulary.meaning(of: "Your Saveback payment") == .cashback)
    }
}
