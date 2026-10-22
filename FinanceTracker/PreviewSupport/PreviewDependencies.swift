#if DEBUG
import Foundation
import SwiftData

@MainActor
enum PreviewDependencies {
    static func dependencies() -> AppDependencies {
        guard let store = try? SwiftDataStore(inMemory: true) else {
            fatalError("Preview store could not be created")
        }
        let dependencies = AppDependencies.make(container: store.container, baseCurrency: .eur)
        seedDemoData(into: store.container)
        return dependencies
    }

    /// Erfundene Demo-Daten für Previews und den Screenshot-Modus
    /// (`-screenshot-demo`, immer in einem isolierten Store).
    nonisolated static func seedDemoData(into container: ModelContainer) {
        let context = ModelContext(container)
        let data = DemoDataFactory.make()
        for account in data.accounts {
            context.insert(SDAccountEntity(from: account))
            // V13-Sidecar: Anfangsbestand (z. B. Geldbeutel) mit einfügen.
            if let opening = account.openingBalance {
                context.insert(SDAccountOpeningBalanceEntity(accountID: account.id, amount: opening, date: account.openingBalanceDate))
            }
        }
        for category in data.categories {
            context.insert(SDCategoryEntity(from: category))
        }
        for merchant in data.merchants {
            context.insert(SDMerchantEntity(from: merchant))
        }
        for transaction in data.transactions {
            context.insert(SDTransactionEntity(from: transaction))
        }
        for collection in data.transactionCollections {
            if let entity = try? SDTransactionCollectionEntity(from: collection) {
                context.insert(entity)
            }
        }
        // Budgets und Fixkosten fehlten bisher, dadurch blieben in
        // Previews Budget-Abschnitt, Verbrauchstempo und Prognose leer,
        // obwohl `DemoDataFactory` beides liefert.
        for budget in data.budgets {
            context.insert(SDBudget2Entity(from: budget))
        }
        for commitment in data.commitments {
            context.insert(SDRecurringCommitmentEntity(from: commitment))
        }
        try? context.save()
    }
}
#endif
