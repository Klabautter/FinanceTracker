import SwiftUI

/// Präsentiert die kanonische `TransactionDetailView` in Kontexten ohne
/// vorhandenes `TransactionsModel` (z. B. Dashboard-Sheet).
struct TransactionDetailSheet: View {
    let transactionID: Transaction.ID
    let dependencies: AppDependencies

    @Environment(\.dismiss) private var dismiss
    @State private var model: TransactionsModel

    init(transactionID: Transaction.ID, dependencies: AppDependencies) {
        self.transactionID = transactionID
        self.dependencies = dependencies
        _model = State(initialValue: TransactionsModel(dependencies: dependencies))
    }

    var body: some View {
        Group {
        #if os(macOS)
        // Kein NavigationStack im Sheet: unter macOS 26 zentriert der
        // Stack-Chrome den Inhalt und reserviert große Leerräume. Eigenes
        // Header-Layout + top-alignierter Inhalt stattdessen.
        VStack(spacing: 0) {
            HStack {
                SheetHeader(title: String(localized: "Transaktionsdetails"))
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.top, AppSpacing.l)
            .padding(.bottom, AppSpacing.s)
            sheetContent
        }
        .background(AppPalette.canvas)
        #else
        NavigationStack {
            sheetContent
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                }
        }
        #endif
        }
        .task(id: transactionID) {
            await model.load(transactionID: transactionID)
        }
        .manualTransactionPresenter(model)
    }

    @ViewBuilder
    private var sheetContent: some View {
        if model.transaction(withID: transactionID) != nil {
            TransactionDetailView(model: model, transactionID: transactionID)
        } else if let errorMessage = model.errorMessage, !model.isLoading {
            ErrorStateView(message: errorMessage) {
                Task { await model.load(transactionID: transactionID) }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
