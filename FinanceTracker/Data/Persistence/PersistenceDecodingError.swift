import Foundation

enum PersistenceDecodingError: Error, Equatable, Sendable {
    case unknownEnum(field: String, raw: String)
    case invalidAmount(field: String, raw: String)
    case unknownStatus(raw: String)
    case unknownSource(raw: String)
    case unknownConditionType(raw: String)
    case invalidJSON(field: String)
    case unknownCollectionOverrideDecision(raw: String)
    case invalidTransactionCollection
    case invalidSharedExpenseShare(field: String, raw: String)

    var userFacingMessage: String {
        switch self {
        case .unknownEnum(let field, let raw):
            String(localized: "Unbekannter Wert in „\(field)“: \(raw)")
        case .invalidAmount(let field, let raw):
            String(localized: "Ungültiger Betrag in „\(field)“: \(raw)")
        case .unknownStatus(let raw):
            String(localized: "Unbekannter Transaktionsstatus: \(raw)")
        case .unknownSource(let raw):
            String(localized: "Unbekannte Transaktionsquelle: \(raw)")
        case .unknownConditionType(let raw):
            String(localized: "Unbekannter Regel-Typ: \(raw)")
        case .invalidJSON(let field):
            String(localized: "Ungültige JSON-Daten in „\(field)“.")
        case .unknownCollectionOverrideDecision(let raw):
            String(localized: "Unbekannte Collection-Override-Entscheidung: \(raw)")
        case .invalidTransactionCollection:
            String(localized: "Ungültiger Zeitraum oder leere Kontenauswahl in der Collection.")
        case .invalidSharedExpenseShare(let field, let raw):
            String(localized: "Ungültiger Gruppenanteil in „\(field)“: \(raw)")
        }
    }
}
