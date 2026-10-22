import SwiftUI

/// Präsentiert Bearbeiten-Formular und Lösch-Rückfrage für manuelle
/// Buchungen. Kontextmenü und Detailbereich setzen nur den Zustand am
/// Model; dieser Modifier hängt einmal am jeweiligen Screen-Root.
struct ManualTransactionPresenter: ViewModifier {
    let model: TransactionsModel

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(item: $model.transactionPendingEdit) { transaction in
                AddTransactionSheet(dependencies: model.dependencies, editing: transaction) {
                    Task { await model.refresh() }
                }
            }
            .sheet(item: $model.categoryCreationTarget) { target in
                CategoryEditorSheet(dependencies: model.dependencies, editing: nil, onSaved: {}, onCreated: { category in
                    Task { await model.categoryCreated(category, for: target) }
                })
            }
            .alert(
                "Buchung löschen?",
                isPresented: Binding(
                    get: { model.transactionPendingDeletion != nil },
                    set: { if !$0 { model.transactionPendingDeletion = nil } }
                ),
                presenting: model.transactionPendingDeletion
            ) { transaction in
                Button("Löschen", role: .destructive) {
                    model.transactionPendingDeletion = nil
                    Task { await model.deleteManualTransaction(transaction) }
                }
                Button("Abbrechen", role: .cancel) {
                    model.transactionPendingDeletion = nil
                }
            } message: { transaction in
                model.isTransferPairLeg(transaction)
                    ? Text("„\(transaction.effectiveMerchantName)“ und die zugehörige Gegenbuchung des Transfers werden entfernt.")
                    : Text("„\(transaction.effectiveMerchantName)“ wird entfernt. Angehängte Belege werden mitgelöscht.")
            }
    }
}

extension View {
    func manualTransactionPresenter(_ model: TransactionsModel) -> some View {
        modifier(ManualTransactionPresenter(model: model))
    }
}
