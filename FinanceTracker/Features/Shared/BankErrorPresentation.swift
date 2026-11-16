import Foundation

/// Fehler der Bankanbindung in Sätzen, die sagen, was los ist und was zu
/// tun ist. Statt „HTTP 401" oder einer rohen API-Antwort steht dort die
/// wahrscheinliche Ursache; der Statuscode bleibt kurz dahinter für
/// Rückfragen erhalten.
enum BankErrorPresentation {
    static func message(for error: Error) -> String {
        if let provider = error as? BankProviderError {
            return message(for: provider)
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return String(localized: "Keine Internetverbindung. Sobald der Mac wieder online ist, erneut versuchen.")
            case .timedOut:
                return String(localized: "Die Bank hat nicht rechtzeitig geantwortet. Bitte später erneut versuchen.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return String(localized: "Enable Banking ist gerade nicht erreichbar. Bitte später erneut versuchen.")
            default:
                break
            }
        }
        return String(localized: "Die Verbindung zur Bank ist fehlgeschlagen. Bitte später erneut versuchen; bleibt der Fehler, unter Konten neu verbinden.")
    }

    static func message(for error: BankProviderError) -> String {
        switch error {
        case .missingCredentials:
            return String(localized: "Der Schlüssel deiner Enable-Banking-Anwendung fehlt auf diesem Mac. Lade die .pem-Datei unter Konten → Datenquelle hinzufügen erneut.")
        case .invalidResponse:
            return String(localized: "Die Bank hat eine unlesbare Antwort geschickt. Bitte später erneut versuchen.")
        case .requestFailed(_, let status, _):
            let reason: String
            switch status {
            case 401, 403:
                reason = String(localized: "Der Zugang wurde abgelehnt: Entweder passt der Schlüssel nicht zur Anwendung, oder die Freigabe der Bank ist abgelaufen. Unter Konten neu verbinden.")
            case 404:
                reason = String(localized: "Diese Verbindung gibt es bei Enable Banking nicht mehr. Unter Konten neu verbinden.")
            case 409, 422:
                reason = String(localized: "Die Anfrage passte nicht zum Stand der Verbindung, etwa weil ein Anmeldecode schon benutzt wurde. Bank-Anmeldung erneut starten.")
            case 429:
                reason = String(localized: "Zu viele Abrufe in kurzer Zeit. Viele Banken erlauben nur wenige Abrufe pro Tag; später erneut versuchen.")
            case 500...599:
                reason = String(localized: "Enable Banking oder die Bank hat gerade eine Störung. Bitte später erneut versuchen.")
            default:
                reason = String(localized: "Die Bank hat die Anfrage abgelehnt.")
            }
            return reason + " " + String(localized: "(Code \(status))")
        }
    }
}
