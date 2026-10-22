import SwiftUI

/// Transaktionsdetail (P1 UX): zeigt die importierten Fakten über die
/// kanonische `TransactionFactsContent`-Komponente (geteilt mit dem Sheet)
/// und erlaubt direkte Korrekturen (Kategorie, Tags, Geprüft,
/// Analyse-Ausschluss), die Aktionen rufen nur Model-Methoden auf.
struct TransactionDetailView: View {
    let model: TransactionsModel
    let transactionID: Transaction.ID

    var body: some View {
        Group {
            if let txn = model.transaction(withID: transactionID) {
                content(txn)
            } else {
                EmptyStateView(
                    title: String(localized: "Transaktion nicht gefunden"),
                    message: String(localized: "Diese Transaktion existiert nicht mehr."),
                    systemImage: "questionmark.folder"
                )
            }
        }
    }

    @ViewBuilder
    private func content(_ txn: Transaction) -> some View {
        #if os(macOS)
        // Statische Fakten-Liste statt Form: Forms zentrieren im macOS-26-
        // Sheet/Inspector-Chrome und reservieren große Leerräume.
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.m) {
                TransactionFactsContent(
                    txn: txn,
                    category: model.category(for: txn),
                    assignableCategories: model.assignableCategories,
                    accountName: model.accountLabelsByID[txn.accountID] ?? model.account(for: txn)?.name,
                    allTags: model.allTags,
                    onAssignCategory: { categoryID, rememberMerchant in
                        Task { await model.assignCategory(txn, to: categoryID, rememberMerchant: rememberMerchant) }
                    },
                    onCreateCategory: { model.categoryCreationTarget = .transaction(txn) },
                    onToggleTag: { tagID in
                        Task { await model.toggleTag(tagID, on: txn) }
                    },
                    onToggleReviewed: { reviewed in
                        Task { await model.toggleReviewed(txn, reviewed: reviewed) }
                    },
                    onToggleExcluded: { excluded in
                        Task { await model.toggleExcluded(txn, excluded: excluded) }
                    },
                    onUpdateNote: { note in
                        Task { await model.updateNote(txn, note: note) }
                    },
                    categoryFooter: merchantCategoryOffer(for: txn)
                )
                GroupExpenseSectionView(transaction: txn, dependencies: model.dependencies)
                    .id(txn.id)
                    .financeCard(padding: AppSpacing.l)
                manualActions(txn)
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppPalette.canvas)
        .accessibilityIdentifier("transaction-detail-content")
        #else
        iOSForm(txn)
        #endif
    }

    /// Nach einer Kategorie-Änderung an dieser Buchung: für alle Buchungen
    /// des Händlers übernehmen? Steht direkt unter der Kategorie-Zeile.
    private func merchantCategoryOffer(for txn: Transaction) -> AnyView? {
        guard let offer = model.merchantCategoryOffer, offer.transactionID == txn.id else { return nil }
        return AnyView(
            MerchantCategoryOfferView(
                offer: offer,
                isStacked: true,
                onApply: { Task { await model.applyMerchantCategoryOffer() } },
                onDismiss: { model.dismissMerchantCategoryOffer() }
            )
        )
    }

    /// Bearbeiten/Löschen gibt es nur für selbst erfasste Buchungen.
    @ViewBuilder
    private func manualActions(_ txn: Transaction) -> some View {
        if model.canDeleteManually(txn) {
            HStack(spacing: AppSpacing.m) {
                if model.canEditManually(txn) {
                    Button("Bearbeiten …") { model.transactionPendingEdit = txn }
                        .accessibilityLabel("Manuelle Buchung bearbeiten")
                        .accessibilityIdentifier("transaction-edit-manual")
                }
                Button("Löschen …", role: .destructive) { model.transactionPendingDeletion = txn }
                    .accessibilityLabel("Manuelle Buchung löschen")
                    .accessibilityIdentifier("transaction-delete-manual")
                Spacer(minLength: 0)
            }
        }
    }

    #if os(iOS)
    private func iOSForm(_ txn: Transaction) -> some View {
        Form {
            TransactionFactsContent(
                txn: txn,
                category: model.category(for: txn),
                assignableCategories: model.assignableCategories,
                accountName: model.accountLabelsByID[txn.accountID] ?? model.account(for: txn)?.name,
                allTags: model.allTags,
                onAssignCategory: { categoryID, rememberMerchant in
                    Task { await model.assignCategory(txn, to: categoryID, rememberMerchant: rememberMerchant) }
                },
                onCreateCategory: { model.categoryCreationTarget = .transaction(txn) },
                onToggleTag: { tagID in
                    Task { await model.toggleTag(tagID, on: txn) }
                },
                onToggleReviewed: { reviewed in
                    Task { await model.toggleReviewed(txn, reviewed: reviewed) }
                },
                onToggleExcluded: { excluded in
                    Task { await model.toggleExcluded(txn, excluded: excluded) }
                },
                onUpdateNote: { note in
                    Task { await model.updateNote(txn, note: note) }
                },
                categoryFooter: merchantCategoryOffer(for: txn)
            )
            GroupExpenseSectionView(transaction: txn, dependencies: model.dependencies)
                .id(txn.id)
            manualActions(txn)
        }
        .accessibilityIdentifier("transaction-detail-content")
        .navigationTitle("Transaktionsdetails")
        .navigationBarTitleDisplayMode(.inline)
    }
    #endif
}
