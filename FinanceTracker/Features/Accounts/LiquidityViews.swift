import SwiftUI

/// Gemeinsame Darstellung des Gesamtstands für Übersicht und Konten-Seite.
@MainActor
enum LiquidityPresentation {
    private static let palette: [CategoryColorToken] = [.blue, .green, .orange, .purple, .teal, .indigo, .yellow, .red]

    static func color(at index: Int) -> Color {
        palette[index % palette.count].color
    }

    /// „Ohne Einnahmen reicht das ≈ 4,2 Monate", ohne Ausgaben `nil`.
    static func runwayText(_ runway: LiquidityRunway) -> String? {
        guard let months = runway.months else { return nil }
        let value = NSDecimalNumber(decimal: months).doubleValue
        if value < 1 {
            return String(localized: "Ohne Einnahmen reicht das weniger als einen Monat")
        }
        if value >= 36 {
            return String(localized: "Ohne Einnahmen reicht das über 3 Jahre")
        }
        let formatted = value.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "Ohne Einnahmen reicht das ≈ \(formatted) Monate")
    }

    static func averageText(_ runway: LiquidityRunway, privacy: PrivacyPresentationState) -> String {
        let amount = PrivacyAwareMoney.string(runway.typicalMonthlySpending, privacy: privacy)
        return runway.monthCount == 1
            ? String(localized: "bei \(amount) Ausgaben im letzten Monat")
            : String(localized: "bei \(amount) Ausgaben im typischen Monat (letzte \(runway.monthCount) Monate)")
    }

    static func netText(_ runway: LiquidityRunway, privacy: PrivacyPresentationState) -> String {
        let amount = PrivacyAwareMoney.signed(runway.typicalMonthlyNet, privacy: privacy)
        return String(localized: "Typischer Monat netto \(amount)")
    }

    /// Hinweise, was in der Summe fehlt oder umgerechnet ist (#35: nichts
    /// wird still weggelassen).
    static func notes(_ overview: LiquidityOverview, now: Date = Date()) -> [String] {
        var notes: [String] = []
        if !overview.withoutBalance.isEmpty {
            let names = overview.withoutBalance.map(\.account.name).joined(separator: ", ")
            notes.append(String(localized: "Ohne bekannten Stand: \(names)"))
        }
        if !overview.unconvertible.isEmpty {
            let names = overview.unconvertible.map(\.account.name).joined(separator: ", ")
            notes.append(String(localized: "Ohne Kurs, nicht enthalten: \(names)"))
        }
        if overview.usesConversion {
            notes.append(String(localized: "Fremdwährungen zum Referenzkurs umgerechnet"))
        }
        if let oldest = overview.oldestReportedAt, now.timeIntervalSince(oldest) > 3 * 24 * 3600 {
            notes.append(String(localized: "Ältester Stand vom \(AppDateFormatter.day(oldest))"))
        }
        return notes
    }

    /// „Stand heute 09:41", „Stand 12.10.2026", „… · umgerechnet aus
    /// 1.375,17 $" oder „aus Anfangsbestand".
    static func asOfText(
        _ summary: AccountSummary,
        privacy: PrivacyPresentationState,
        calendar: Calendar = .current
    ) -> String? {
        switch summary.balanceBasis {
        case .reported:
            guard let date = summary.balanceReportedAt else { return nil }
            let stand = calendar.isDateInToday(date)
                ? String(localized: "Stand heute \(date.formatted(date: .omitted, time: .shortened))")
                : String(localized: "Stand \(AppDateFormatter.day(date))")
            guard let original = summary.balanceConvertedFrom else { return stand }
            let amount = PrivacyAwareMoney.string(original, privacy: privacy)
            return String(localized: "\(stand) · umgerechnet aus \(amount)")
        case .openingBalance:
            return String(localized: "aus Anfangsbestand")
        case nil:
            return nil
        }
    }
}

/// Anteile der Konten am Guthaben als ein durchgehender Balken.
struct LiquidityShareBar: View {
    let overview: LiquidityOverview
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let segments = overview.shares.enumerated().filter { $0.element.fraction > 0 }
            let spacing: CGFloat = 2
            let available = max(0, proxy.size.width - spacing * CGFloat(max(0, segments.count - 1)))
            HStack(spacing: spacing) {
                ForEach(segments, id: \.element.id) { index, share in
                    Capsule()
                        .fill(LiquidityPresentation.color(at: index))
                        .frame(width: max(height, available * share.fraction))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Hinweise unter dem Gesamtstand, eng gesetzt.
struct LiquidityNotes: View {
    let overview: LiquidityOverview

    var body: some View {
        let notes = LiquidityPresentation.notes(overview)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Konto mit Farbpunkt, Stand und Anteil.
struct LiquidityLegendRow: View {
    let share: LiquidityOverview.Share
    let index: Int
    @Environment(PrivacyPresentationState.self) private var privacyState

    var body: some View {
        HStack(spacing: AppSpacing.s) {
            Circle()
                .fill(share.fraction > 0 ? LiquidityPresentation.color(at: index) : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(share.summary.account.name)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: AppSpacing.s)
            if share.fraction > 0 {
                Text(share.fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if share.isConverted {
                Text("≈ \(PrivacyAwareMoney.string(share.converted, privacy: privacyState))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(PrivacyAwareMoney.string(share.balance, privacy: privacyState))
                .font(AppTypography.amount)
                .monospacedDigit()
                .foregroundStyle(share.balance.amount < 0 ? AppPalette.critical : Color.primary)
        }
        .accessibilityElement(children: .combine)
    }
}
