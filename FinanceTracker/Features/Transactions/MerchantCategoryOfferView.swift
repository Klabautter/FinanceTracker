import SwiftUI

/// Rückfrage nach einer einzelnen Kategorie-Änderung: dieselbe Kategorie für
/// alle Buchungen des Händlers übernehmen? Über der Tabelle als Zeile, im
/// schmalen Detailbereich gestapelt.
struct MerchantCategoryOfferView: View {
    let offer: TransactionsModel.MerchantCategoryOffer
    var isStacked = false
    let onApply: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if isStacked {
                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    message
                    HStack(spacing: AppSpacing.s) {
                        applyButton
                        Button("Nur diese", action: onDismiss)
                            .controlSize(.small)
                            .accessibilityLabel("Nur diese Buchung ändern")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: AppSpacing.m) {
                    message
                    Spacer(minLength: AppSpacing.s)
                    applyButton
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Nur diese Buchung ändern")
                    .accessibilityLabel("Nur diese Buchung ändern")
                }
            }
        }
        .padding(.vertical, isStacked ? 12 : 8)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(AppPalette.sunken)
        )
        .accessibilityIdentifier("transactions-merchant-category-offer")
    }

    private var message: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(AppPalette.brand)
                .accessibilityHidden(true)
            Text(offer.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var applyButton: some View {
        Button(offer.otherCount == 0 ? String(localized: "Künftig so zuordnen") : String(localized: "Für alle ändern"), action: onApply)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("transactions-merchant-category-apply")
    }
}
