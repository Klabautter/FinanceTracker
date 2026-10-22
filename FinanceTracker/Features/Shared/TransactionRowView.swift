import SwiftUI

struct TransactionRowView: View {
    let transaction: Transaction
    let category: Category?

    @Environment(PrivacyPresentationState.self) private var privacyState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category?.systemIconName ?? "tag")
                .font(.body)
                .foregroundStyle(category?.colorToken.color ?? .secondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.effectiveMerchantName)
                    .lineLimit(1)
                if let raw = transaction.rawDescription, raw != transaction.effectiveMerchantName {
                    Text(raw)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(money: transaction.amount, signed: true)
                HStack(spacing: 4) {
                    if transaction.status == .pending {
                        Text("Ausstehend")
                            .font(.caption2)
                            .foregroundStyle(AppPalette.warning)
                    }
                    Text(AppDateFormatter.weekdayDay(transaction.displayDate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let categoryName = category?.name ?? Category.uncategorizedDisplayName
        return "\(transaction.effectiveMerchantName), \(categoryName), \(PrivacyAwareMoney.accessibilityLabel(transaction.amount, privacy: privacyState, signed: true))"
    }
}
