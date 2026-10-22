import SwiftUI

/// Split-Sektion im Transaction Detail (Roadmap #67/#70).
struct TransactionSplitSection: View {
    let transaction: Transaction
    let dependencies: AppDependencies

    @State private var splits: [TransactionSplitLine] = []
    @State private var showsSplitEditor = false
    @State private var isLoading = false
    @Environment(PrivacyPresentationState.self) private var privacyState

    var body: some View {
        Section("Split") {
            if isLoading {
                ProgressView()
            } else if splits.isEmpty {
                Button {
                    showsSplitEditor = true
                } label: {
                    Label("In Positionen splitten", systemImage: "square.split.2x1")
                }
                .accessibilityLabel("Diese Transaktion in Positionen splitten")
            } else {
                ForEach(splits) { line in
                    HStack {
                        Text(line.note ?? String(localized: "Position"))
                            .lineLimit(1)
                        Spacer()
                        Text(PrivacyAwareMoney.decimalString(line.amount, currency: transaction.amount.currency, privacy: privacyState))
                            .font(.callout.monospacedDigit())
                    }
                }

                Button("Split bearbeiten") {
                    showsSplitEditor = true
                }
                .font(.caption)
            }
        }
        .task(id: transaction.id) {
            splits = []
            showsSplitEditor = false
            await load(transactionID: transaction.id)
        }
        .sheet(isPresented: $showsSplitEditor) {
            TransactionSplitSheet(
                parent: transaction,
                dependencies: dependencies,
                onSaved: {
                    let transactionID = transaction.id
                    Task { await load(transactionID: transactionID) }
                }
            )
            .id(transaction.id)
        }
    }

    private func load(transactionID: Transaction.ID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await dependencies.transactionSplitRepository.splitLines(
                parentTransactionID: transactionID
            )
            guard !Task.isCancelled, transaction.id == transactionID else { return }
            splits = loaded
        } catch {
            guard transaction.id == transactionID else { return }
            splits = []
        }
    }
}
