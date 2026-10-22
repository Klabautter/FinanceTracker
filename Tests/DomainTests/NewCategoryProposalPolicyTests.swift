import Foundation
import Testing

@testable import FinanceTracker

@Suite("NewCategoryProposalPolicy")
struct NewCategoryProposalPolicyTests {
    @Test("Singular und Plural, Groß-/Kleinschreibung und Umlaut-Punkte gelten als gleich")
    func keys() {
        #expect(NewCategoryProposalPolicy.key("Versicherungen") == NewCategoryProposalPolicy.key("versicherung"))
        #expect(NewCategoryProposalPolicy.key("Gebühren") == NewCategoryProposalPolicy.key("GEBUHR"))
        #expect(NewCategoryProposalPolicy.key("Haustiere") == NewCategoryProposalPolicy.key("Haustier"))
    }

    @Test("Unbrauchbare Vorschläge werden verworfen")
    func cleaning() {
        #expect(NewCategoryProposalPolicy.cleanedName("versicherungen.", merchantName: "Techniker Krankenkasse") == "Versicherungen")
        #expect(NewCategoryProposalPolicy.cleanedName("Techniker Krankenkasse", merchantName: "Techniker Krankenkasse") == nil)
        #expect(NewCategoryProposalPolicy.cleanedName("", merchantName: "X") == nil)
        #expect(NewCategoryProposalPolicy.cleanedName("Sehr lange Kategorie mit vielen Wörtern", merchantName: "X") == nil)
    }

    @Test("Eine vorhandene Kategorie gleichen Namens hat Vorrang")
    func existingMatch() {
        let insurance = FinanceTracker.Category(name: "Versicherungen", systemIconName: "shield", colorToken: .teal)
        #expect(NewCategoryProposalPolicy.existingMatch(for: "Versicherung", in: [insurance])?.id == insurance.id)
        #expect(NewCategoryProposalPolicy.existingMatch(for: "Spenden", in: [insurance]) == nil)
    }

    @Test("Ein neuer Vorschlag braucht ein Branchenwort, das wirklich im Namen steht")
    func grounding() {
        #expect(NewCategoryProposalPolicy.isGrounded(evidence: "Krankenkasse", in: "Techniker Krankenkasse"))
        #expect(NewCategoryProposalPolicy.isGrounded(evidence: "Versicherungs", in: "Allianz Versicherungs-AG"))
        #expect(NewCategoryProposalPolicy.isGrounded(evidence: "Kfz-Steuer", in: "Stadt Musterstadt Kfz-Steuer"))
        #expect(!NewCategoryProposalPolicy.isGrounded(evidence: "Versicherung", in: "Mol*Ravis GmbH"))
        #expect(!NewCategoryProposalPolicy.isGrounded(evidence: "GmbH", in: "Mol*Ravis GmbH"))
        #expect(NewCategoryProposalPolicy.cleanedName("Zahlungen", merchantName: "X") == nil)
    }

    @Test("Teile vorhandener Namen sind keine neue Kategorie")
    func overlap() {
        let food = FinanceTracker.Category(name: "Essen & Trinken", systemIconName: "fork.knife", colorToken: .orange)
        #expect(NewCategoryProposalPolicy.overlapsExisting("Essen", in: [food]))
        #expect(!NewCategoryProposalPolicy.overlapsExisting("Versicherungen", in: [food]))
    }
}
