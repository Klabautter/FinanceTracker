import SwiftUI

struct PocketTransactionPicker: View {
    let model: PocketsModel

    @State private var searchText = ""
    @State private var accountID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyPresentationState.self) private var privacyState

    private struct CandidateScope: Hashable {
        let searchText: String
        let accountID: UUID?
    }

    var body: some View {
        AdaptiveSheet(title: String(localized: "Transaktion hinzufügen")) {
            Group {
                if model.isLoadingCandidates {
                    LoadingStateView(label: String(localized: "Lade verfügbare Transaktionen…"))
                } else if model.candidateRows.isEmpty {
                    EmptyStateView(
                        title: String(localized: "Keine Transaktionen verfügbar"),
                        message: String(localized: "Alle vorhandenen Transaktionen liegen bereits im automatischen Scope oder wurden hinzugefügt."),
                        systemImage: "checkmark.circle"
                    )
                } else {
                    List(model.candidateRows) { row in
                        HStack(spacing: AppSpacing.m) {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(row.merchant).fontWeight(.medium)
                                Text("\(AppDateFormatter.day(row.date)) · \(row.account) · \(row.category)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(PrivacyAwareMoney.signed(row.transaction.amount, privacy: privacyState))
                                .monospacedDigit()
                                .accessibilityLabel(
                                    PrivacyAwareMoney.accessibilityLabel(
                                        row.transaction.amount,
                                        privacy: privacyState,
                                        signed: true
                                    )
                                )
                            Button("Hinzufügen") {
                                Task {
                                    await model.include(row.transaction)
                                    dismiss()
                                }
                            }
                            .disabled(model.isMutating)
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Händler, Konto oder Kategorie")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem {
                    Menu {
                        Button("Alle Konten") { accountID = nil }
                        ForEach(model.accounts) { account in
                            Button(account.name) { accountID = account.id }
                        }
                    } label: {
                        Label(
                            accountID.flatMap { id in model.accounts.first { $0.id == id }?.name } ?? String(localized: "Alle Konten"),
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    }
                    .accessibilityLabel("Nach Konto filtern")
                }
            }
            .task(id: CandidateScope(searchText: searchText, accountID: accountID)) {
                if !searchText.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                }
                await model.loadCandidates(searchText: searchText, accountID: accountID)
            }
        }
        #if os(macOS)
        .frame(width: 720, height: 560)
        #endif
    }
}
