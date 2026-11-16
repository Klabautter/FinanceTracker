import Foundation
import Testing

@testable import FinanceTracker

@MainActor
@Suite("BaseCurrencyPreference")
struct BaseCurrencyPreferenceTests {
    @Test("Gespeicherte Basiswährung wird nur mit Referenzkurs übernommen")
    func storedCurrencyIsValidated() {
        let defaults = UserDefaults(suiteName: "base-currency-\(UUID().uuidString)")!
        #expect(AppDependencies.storedBaseCurrency(in: defaults) == .eur)
        defaults.set("CHF", forKey: AppDependencies.baseCurrencyDefaultsKey)
        #expect(AppDependencies.storedBaseCurrency(in: defaults) == CurrencyCode("CHF"))
        defaults.set("XYZ", forKey: AppDependencies.baseCurrencyDefaultsKey)
        #expect(AppDependencies.storedBaseCurrency(in: defaults) == .eur)
    }

    @Test("Übersicht rechnet Euro-Buchungen in die gewählte Basiswährung um")
    func dashboardUsesBaseCurrency() async throws {
        let store = try SwiftDataStore(inMemory: true)
        PreviewDependencies.seedDemoData(into: store.container)
        let euro = AppDependencies.make(container: store.container, baseCurrency: .eur)
        let franc = AppDependencies.make(container: store.container, baseCurrency: CurrencyCode("CHF"))
        let euroModel = DashboardModel(dependencies: euro)
        let francModel = DashboardModel(dependencies: franc)
        await euroModel.load()
        await francModel.load()
        let euroSpending = try #require(euroModel.snapshot?.totalSpending)
        let francSpending = try #require(francModel.snapshot?.totalSpending)
        #expect(francModel.snapshot?.baseCurrency == CurrencyCode("CHF"))
        #expect(euroSpending > 0 && francSpending > 0)
        #expect(euroSpending != francSpending)
    }
}
