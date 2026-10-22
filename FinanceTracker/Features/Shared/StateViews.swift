import SwiftUI

struct EmptyStateView<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    var tint: Color = AppPalette.brand
    private let actions: Actions

    init(
        title: String,
        message: String,
        systemImage: String,
        tint: Color = AppPalette.brand,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: AppSpacing.m) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.08))
                    .frame(width: 88, height: 88)
                IconTile(systemName: systemImage, color: tint, size: 52)
            }
            .accessibilityHidden(true)
            Text(title)
                .font(.system(.title3).weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
            if Actions.self != EmptyView.self {
                VStack(spacing: AppSpacing.s) {
                    actions
                }
                .controlSize(.large)
                .padding(.top, AppSpacing.s)
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(title: String, message: String, systemImage: String, tint: Color = AppPalette.brand) {
        self.init(title: title, message: message, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

struct ErrorStateView: View {
    let message: String
    var retryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: AppSpacing.m) {
            IconTile(systemName: "exclamationmark.triangle.fill", color: AppPalette.critical, size: 56)
            Text("Etwas ist schiefgelaufen")
                .font(.system(.title3, design: .rounded).weight(.bold))
            Text(message)
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            if let retryAction {
                Button("Erneut versuchen", action: retryAction)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, AppSpacing.xs)
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoadingStateView: View {
    var label: String = String(localized: "Lade Daten…")

    var body: some View {
        VStack(spacing: AppSpacing.m) {
            ProgressView()
                .controlSize(.regular)
            Text(label)
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// Reine Darstellungslogik des Kursstatus (ohne SwiftUI testbar).
/// Eine Zeile, neutral solange der Kurs frisch ist. Warnung nur, wenn der
/// Kurs als veraltet markiert ist oder das Kursdatum älter als `warningAge`
/// ist; ein fehlgeschlagener Refresh bei frischem Cache ist kein Alarm.
enum FXRateStatusPresentation {
    /// Ab diesem Alter des Kursdatums gilt der Kurs als veraltet.
    static let warningAge: TimeInterval = 30 * 24 * 60 * 60

    static var explanation: String {
        String(localized: "Fremdwährungsbuchungen nutzen diesen Referenzkurs. Historische Beträge sind Näherungen, keine Kurse vom Buchungstag.")
    }

    static func quoteDate(for snapshot: FXRateSnapshot) -> Date? {
        if let date = snapshot.quoteDate { return date }
        if snapshot.source == .fallback { return CurrencyConverter.referenceEURQuoteDate }
        return nil
    }

    static func isWarning(_ snapshot: FXRateSnapshot, now: Date = Date()) -> Bool {
        if snapshot.isStale { return true }
        guard let date = quoteDate(for: snapshot) else { return true }
        return now.timeIntervalSince(date) > warningAge
    }

    /// Kompakt: „EZB-Referenzkurs · Stand 1. Okt. 2026"; bei Warnung mit
    /// Präfix „Kurs veraltet" und ggf. „Aktualisierung fehlgeschlagen".
    /// `detailed` (Einstellungen) nennt Abrufdatum und Refresh-Fehler immer.
    static func text(for snapshot: FXRateSnapshot, now: Date = Date(), detailed: Bool = false) -> String {
        let dateText = quoteDate(for: snapshot).map { AppDateFormatter.day($0) } ?? String(localized: "unbekannt")
        let sourceText = switch snapshot.source {
        case .live: String(localized: "EZB-Referenzkurs")
        case .cache: String(localized: "EZB-Referenzkurs aus Cache")
        case .fallback: String(localized: "Statischer Richtkurs")
        }
        let warning = isWarning(snapshot, now: now)
        var parts: [String] = []
        if warning { parts.append(String(localized: "Kurs veraltet")) }
        parts.append(String(localized: "\(sourceText) · Stand \(dateText)"))
        if detailed, let fetched = snapshot.fetchedAt {
            parts.append(String(localized: "abgerufen \(AppDateFormatter.day(fetched))"))
        }
        if snapshot.refreshFailed, warning || detailed {
            parts.append(String(localized: "Aktualisierung fehlgeschlagen"))
        }
        return parts.joined(separator: " · ")
    }

    static func systemImage(for snapshot: FXRateSnapshot, now: Date = Date()) -> String {
        isWarning(snapshot, now: now) ? "exclamationmark.triangle" : "arrow.left.arrow.right.circle"
    }
}

/// Kompakte FX-Statuszeile (EZB-Kurse, #19/#35): eine Zeile, Erklärung als
/// Tooltip. Reine Präsentation: Kurse kommen als `FXRateSnapshot` herein.
/// Verhalten: lädt (`isLoading`, noch kein Snapshot) → Ladezeile;
/// Snapshot → Quelle + Stand; `nil` ohne Laden → keine Fremdwährung im
/// Scope, die Zeile blendet sich aus. `detailed` (Einstellungen) zeigt die
/// Erklärung zusätzlich als Text.
struct FXRateStatusView: View {
    let snapshot: FXRateSnapshot?
    let isLoading: Bool
    var detailed: Bool = false

    var body: some View {
        Group {
            if isLoading, snapshot == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Kurse werden geladen…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Wechselkurse werden geladen")
            } else if let snapshot {
                let warning = FXRateStatusPresentation.isWarning(snapshot)
                let text = FXRateStatusPresentation.text(for: snapshot, detailed: detailed)
                VStack(alignment: .leading, spacing: 3) {
                    Label(text, systemImage: FXRateStatusPresentation.systemImage(for: snapshot))
                        .font(.caption.weight(warning ? .medium : .regular))
                        .foregroundStyle(warning ? AppPalette.warning : Color.secondary)
                        .accessibilityLabel("Wechselkurs-Status: \(text)")
                        .help(FXRateStatusPresentation.explanation)
                    if detailed {
                        Text(FXRateStatusPresentation.explanation)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityIdentifier("fx-rate-status")
    }
}

/// Gemeinsamer, kompakter Hinweis zu umgerechneten/ausgeschlossenen
/// Fremdwährungen inklusive Kursstatus.
struct CurrencyConversionNotice: View {
    let snapshot: AnalyticsSnapshot
    let baseCurrency: CurrencyCode
    let fxSnapshot: FXRateSnapshot?
    let fxIsLoading: Bool

    var body: some View {
        if snapshot.convertedForeignTransactionCount > 0 || snapshot.excludedForeignTransactionCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                if snapshot.excludedForeignTransactionCount > 0 {
                    let count = snapshot.excludedForeignTransactionCount
                    let currencies = snapshot.excludedCurrencies.map(\.rawValue).sorted().joined(separator: ", ")
                    Label(
                        count == 1
                            ? String(localized: "1 Transaktion in \(currencies) ist nicht in den Summen enthalten (kein Referenzkurs).")
                            : String(localized: "\(count) Transaktionen in \(currencies) sind nicht in den Summen enthalten (kein Referenzkurs)."),
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(AppPalette.warning)
                }
                if snapshot.convertedForeignTransactionCount > 0 {
                    let count = snapshot.convertedForeignTransactionCount
                    let currencies = snapshot.convertedCurrencies.map(\.rawValue).sorted().joined(separator: ", ")
                    Label(
                        count == 1
                            ? String(localized: "1 Transaktion in \(currencies) wurde zum Referenzkurs in \(baseCurrency.rawValue) umgerechnet.")
                            : String(localized: "\(count) Transaktionen in \(currencies) wurden zum Referenzkurs in \(baseCurrency.rawValue) umgerechnet."),
                        systemImage: "arrow.left.arrow.right.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                FXRateStatusView(snapshot: fxSnapshot, isLoading: fxIsLoading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(AppPalette.sunken)
            )
        }
    }
}
