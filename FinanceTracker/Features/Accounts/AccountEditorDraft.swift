import Foundation

/// Formularzustand für „Konto anlegen/bearbeiten": reine Logik ohne
/// SwiftUI, damit Validierung und Ergebnis testbar sind.
struct AccountEditorDraft: Equatable, Sendable {
    var name: String
    var type: AccountType
    var currency: CurrencyCode
    var hasOpeningBalance: Bool
    var openingBalance: Decimal?
    var openingBalanceDate: Date
    let editing: Account?
    let transactionCount: Int

    init(editing: Account?, transactionCount: Int, baseCurrency: CurrencyCode, now: Date = Date()) {
        self.editing = editing
        self.transactionCount = transactionCount
        name = editing?.name ?? ""
        type = editing?.type ?? .cash
        currency = editing?.currency ?? baseCurrency
        hasOpeningBalance = editing?.openingBalance != nil
        openingBalance = editing?.openingBalance
        openingBalanceDate = editing?.openingBalanceDate ?? now
    }

    var isNew: Bool { editing == nil }

    /// Die Währung bleibt fest, sobald Buchungen daran hängen (nie
    /// Währungen vermischen) oder die Bank sie vorgibt.
    var canChangeCurrency: Bool {
        guard let editing else { return true }
        return transactionCount == 0 && editing.source != .openBanking
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var validationMessage: String? {
        if trimmedName.isEmpty { return String(localized: "Bitte einen Kontonamen eingeben.") }
        if hasOpeningBalance, openingBalance == nil {
            return String(localized: "Bitte einen Anfangsbestand eingeben oder die Option ausschalten.")
        }
        return nil
    }

    var canSave: Bool { validationMessage == nil }

    func makeAccount() -> Account {
        var account = editing ?? Account(name: trimmedName, type: type, currency: currency, source: .manual)
        account.name = trimmedName
        account.type = type
        if canChangeCurrency { account.currency = currency }
        account.openingBalance = hasOpeningBalance ? openingBalance : nil
        account.openingBalanceDate = hasOpeningBalance ? openingBalanceDate : nil
        return account
    }
}
