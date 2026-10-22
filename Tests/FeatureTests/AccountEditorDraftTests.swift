import Foundation
import Testing

@testable import FinanceTracker

@Suite("AccountEditorDraft")
struct AccountEditorDraftTests {
    @Test("Neues Konto: Bargeld als Standard, Basiswährung, Name Pflicht")
    func newAccountDefaults() {
        var draft = AccountEditorDraft(editing: nil, transactionCount: 0, baseCurrency: .eur)
        #expect(draft.isNew)
        #expect(draft.type == .cash)
        #expect(draft.currency == .eur)
        #expect(draft.canChangeCurrency)
        #expect(!draft.canSave)
        #expect(draft.validationMessage == "Bitte einen Kontonamen eingeben.")

        draft.name = "  Geldbeutel "
        #expect(draft.canSave)
        let account = draft.makeAccount()
        #expect(account.name == "Geldbeutel")
        #expect(account.type == .cash)
        #expect(account.source == .manual)
        #expect(account.openingBalance == nil)
        #expect(account.isActive)
    }

    @Test("Anfangsbestand: eingeschaltet ohne Betrag ist ungültig, ausgeschaltet wird er entfernt")
    func openingBalanceValidation() {
        let stichtag = Date(timeIntervalSince1970: 1_790_000_000)
        var draft = AccountEditorDraft(editing: nil, transactionCount: 0, baseCurrency: .eur, now: stichtag)
        draft.name = "Bargeld"
        draft.hasOpeningBalance = true
        #expect(!draft.canSave)
        #expect(draft.validationMessage?.contains("Anfangsbestand") == true)

        draft.openingBalance = Decimal(string: "120.50")
        #expect(draft.canSave)
        let account = draft.makeAccount()
        #expect(account.openingBalance == Decimal(string: "120.50"))
        #expect(account.openingBalanceDate == stichtag)

        var edit = AccountEditorDraft(editing: account, transactionCount: 0, baseCurrency: .eur)
        #expect(edit.hasOpeningBalance)
        edit.hasOpeningBalance = false
        let cleared = edit.makeAccount()
        #expect(cleared.id == account.id)
        #expect(cleared.openingBalance == nil)
        #expect(cleared.openingBalanceDate == nil)
    }

    @Test("Währung bleibt fest bei Buchungen oder Bankquelle; Name und Typ bleiben änderbar")
    func currencyLock() {
        let bank = Account(name: "Giro", type: .checking, currency: .eur, source: .openBanking)
        var bankDraft = AccountEditorDraft(editing: bank, transactionCount: 0, baseCurrency: .eur)
        #expect(!bankDraft.canChangeCurrency)
        bankDraft.currency = .usd
        bankDraft.name = "Hauptkonto"
        bankDraft.type = .savings
        let saved = bankDraft.makeAccount()
        #expect(saved.currency == .eur)
        #expect(saved.name == "Hauptkonto")
        #expect(saved.type == .savings)
        #expect(saved.source == .openBanking)

        let manual = Account(name: "Cash", type: .cash, currency: .eur, source: .manual)
        #expect(AccountEditorDraft(editing: manual, transactionCount: 3, baseCurrency: .eur).canChangeCurrency == false)
        #expect(AccountEditorDraft(editing: manual, transactionCount: 0, baseCurrency: .eur).canChangeCurrency)
    }
}
