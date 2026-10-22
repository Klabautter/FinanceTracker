import Foundation

/// Normalisiert den Provider-„Unbekannt"-Zustand beim Import: Der Typ wird
/// deterministisch aus dem Betragssignal abgeleitet (positiv → Einnahme,
/// negativ → Kauf), exakt die Semantik, die die CashflowPolicy für
/// unbekannte Typen ohnehin anwendet. Damit stimmt der gespeicherte Typ mit
/// der überall konsumierten effektiven Semantik überein.
///
/// Explizite Provider-Typen bleiben unverändert. Transfer und Erstattung
/// werden nur bei einem ausdrücklichen Textsignal gesetzt; alles andere
/// bleibt Detektor- bzw. User-Entscheidung über die Prüfliste, keine
/// stillen Spekulationen.
enum TransactionKindInference: Sendable {
    static func inferredKind(
        for amount: Money,
        current: TransactionKind,
        rawDescription: String? = nil,
        merchantName: String? = nil
    ) -> TransactionKind {
        guard current == .unknown else { return current }
        if hasStrongTransferSignal(rawDescription: rawDescription, merchantName: merchantName) {
            return .transfer
        }
        if amount.amount > 0, hasStrongRefundSignal(rawDescription: rawDescription) {
            return .refund
        }
        return amount.amount >= 0 ? .income : .purchase
    }

    /// Ein Zahlungseingang, dessen Verwendungszweck ihn ausdrücklich als
    /// Erstattung bezeichnet, mindert die Ausgaben statt als Einnahme zu
    /// zählen. Nur ganze Wörter: „Steuererstattung" ist keine Händler-
    /// Rückzahlung und bleibt Einnahme.
    static func hasStrongRefundSignal(rawDescription: String?) -> Bool {
        let description = CategoryRuleEngine.normalizedKey(rawDescription ?? "")
        return ["REFUND", "ERSTATTUNG", "RUCKERSTATTUNG", "RUECKERSTATTUNG", "RETOURE"].contains {
            CategoryRuleEngine.containsTokenSequence(description, $0)
        }
    }

    /// Nur explizite Eigenübertrags-Begriffe gelten als stark genug für eine
    /// automatische Transfer-Semantik. „Sparrate" allein ist mehrdeutig
    /// (z. B. ETF-Sparplan) und zählt daher nur zusammen mit einem klar als
    /// eigenes Konto bezeichneten Gegenkonto. Betragspaare ohne Textsignal
    /// bleiben weiterhin bestätigungspflichtige Kandidaten in der Review Queue.
    static func hasStrongTransferSignal(
        rawDescription: String?,
        merchantName: String?
    ) -> Bool {
        let description = CategoryRuleEngine.normalizedKey(rawDescription ?? "")
        let merchant = CategoryRuleEngine.normalizedKey(merchantName ?? "")
        let explicitTransfer = ["UMBUCHUNG", "EIGENUBERTRAG", "EIGENUEBERTRAG"].contains {
            CategoryRuleEngine.containsTokenSequence(description, $0)
                || CategoryRuleEngine.containsTokenSequence(merchant, $0)
        }
        if explicitTransfer { return true }

        let isSavingsRate = CategoryRuleEngine.containsTokenSequence(description, "SPARRATE")
        let isOwnAccount = ["EIGENES KONTO", "EIGENES GIROKONTO", "EIGENES TAGESGELD"].contains {
            CategoryRuleEngine.containsTokenSequence(merchant, $0)
        }
        return isSavingsRate && isOwnAccount
    }
}
