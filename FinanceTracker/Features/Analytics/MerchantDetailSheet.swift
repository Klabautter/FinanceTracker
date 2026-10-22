import SwiftUI

@MainActor
@Observable
final class MerchantDetailModel {
    let merchantName: String
    let scope: AnalyticsScope
    let currency: CurrencyCode

    private let dependencies: AppDependencies
    private let effectiveTransactionResolver = EffectiveTransactionResolver()
    private let cashflowPolicy = CashflowPolicy.shared

    private(set) var total: Decimal?
    private(set) var transactions: [Transaction] = []
    /// Währungen, die ohne Referenzkurs nicht in der Summe enthalten sind.
    private(set) var excludedCurrencies: Set<CurrencyCode> = []
    /// Währungen, die zum Referenzkurs in die Basiswährung umgerechnet sind.
    private(set) var convertedCurrencies: Set<CurrencyCode> = []
    private(set) var fxSnapshot: FXRateSnapshot?
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    init(merchantName: String, scope: AnalyticsScope, dependencies: AppDependencies) {
        self.merchantName = merchantName
        self.scope = scope
        self.currency = dependencies.baseCurrency
        self.dependencies = dependencies
    }

    var transactionCount: Int { transactions.count }

    var average: Decimal? {
        guard transactionCount > 0, let total else { return nil }
        return total / Decimal(transactionCount)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        fxSnapshot = nil

        do {
            let candidates = try await dependencies.transactionRepository.transactions(
                matching: scope.query(searchText: merchantName)
            )
            let annotations = try await dependencies.transactionAnnotationRepository.annotations(
                transactionIDs: Set(candidates.map(\.id))
            )
            let effective = effectiveTransactionResolver.applying(
                annotations: annotations,
                to: candidates
            )
            let targetName = normalizedMerchantName(merchantName)
            let baseCurrency = dependencies.baseCurrency
            let matchingSpending = effective.filter { transaction in
                normalizedMerchantName(transaction.effectiveMerchantName) == targetName
                    && transaction.status != .reversed
                    && transaction.status != .cancelled
                    && !cashflowPolicy.isExcluded(transaction)
                    && cashflowPolicy.countsTowardBreakdowns(transaction)
            }

            // Produkt-Entscheid 29.08.2026: Fremdwährungen fließen zum
            // Kurs des FX-Snapshots (live → 24h-Cache → Referenzkurse) in
            // die Summe ein; ohne Kurs → transparent ausgeschlossen (#17).
            // Die Zeilenliste zeigt weiterhin den Original-Betrag der Buchung.
            // Reine Basiswährung braucht kein FX-I/O.
            let converter: CurrencyConverter
            if matchingSpending.contains(where: { $0.amount.currency != baseCurrency }) {
                let snapshot = await dependencies.fxRateProvider.snapshot()
                fxSnapshot = snapshot
                converter = CurrencyConverter(eurPerUnit: snapshot.eurPerUnit)
            } else {
                converter = CurrencyConverter()
            }
            var convertedTotal: Decimal = 0
            var converted: Set<CurrencyCode> = []
            var excluded: Set<CurrencyCode> = []
            var included: [Transaction] = []
            for transaction in matchingSpending {
                guard let baseAmount = converter.convert(transaction.amount, to: baseCurrency) else {
                    excluded.insert(transaction.amount.currency)
                    continue
                }
                if transaction.amount.currency != baseCurrency {
                    converted.insert(transaction.amount.currency)
                }
                convertedTotal += abs(baseAmount.amount)
                included.append(transaction)
            }

            transactions = included.sorted {
                if $0.displayDate != $1.displayDate { return $0.displayDate > $1.displayDate }
                return $0.id.uuidString < $1.id.uuidString
            }
            total = convertedTotal
            convertedCurrencies = converted
            excludedCurrencies = excluded
            isLoading = false
        } catch {
            total = nil
            transactions = []
            excludedCurrencies = []
            convertedCurrencies = []
            errorMessage = String(localized: "Händler-Daten konnten nicht geladen werden.")
            isLoading = false
        }
    }

    private func normalizedMerchantName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}

/// Händler-Detail für exakt denselben Query-Scope und dieselbe effektive
/// Transaktionssemantik wie die Ausgangsanalyse.
struct MerchantDetailSheet: View {
    @State private var model: MerchantDetailModel
    @Environment(\.dismiss) private var dismiss
    @Environment(PrivacyPresentationState.self) private var privacyState

    init(merchantName: String, scope: AnalyticsScope, dependencies: AppDependencies) {
        _model = State(initialValue: MerchantDetailModel(
            merchantName: merchantName,
            scope: scope,
            dependencies: dependencies
        ))
    }

    var body: some View {
        AdaptiveSheet(title: model.merchantName) {
            Group {
                if model.isLoading {
                    LoadingStateView(label: String(localized: "Händler im gewählten Analysebereich laden…"))
                } else if let errorMessage = model.errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await model.load() }
                    }
                } else {
                    content
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                        .accessibilityHint("Schließt das Händlerdetail")
                }
            }
        }
        .task { await model.load() }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 480)
        #endif
    }

    private var content: some View {
        Form {
            Section("Analysebereich") {
                Label(model.scope.summary, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Analysebereich: \(model.scope.summary)")
            }

            Section {
                if let total = model.total {
                    LabeledMetric(
                        label: String(localized: "Ausgaben im Analysebereich"),
                        value: amountText(total),
                        valueColor: .primary
                    )
                }
                LabeledMetric(
                    label: String(localized: "Transaktionen"),
                    value: "\(model.transactionCount)"
                )
                if let average = model.average {
                    LabeledMetric(
                        label: String(localized: "Durchschnitt pro Transaktion"),
                        value: amountText(average)
                    )
                }
                if !model.convertedCurrencies.isEmpty {
                    Label(
                        "Beträge in \(model.convertedCurrencies.map(\.rawValue).sorted().joined(separator: ", ")) wurden zum Referenzkurs in \(model.currency.rawValue) umgerechnet.",
                        systemImage: "arrow.left.arrow.right.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !model.excludedCurrencies.isEmpty {
                    Label(
                        "Beträge in \(model.excludedCurrencies.map(\.rawValue).sorted().joined(separator: ", ")) sind nicht in der Summe enthalten (kein Referenzkurs).",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(AppPalette.warning)
                }
                if model.fxSnapshot != nil {
                    FXRateStatusView(snapshot: model.fxSnapshot, isLoading: model.isLoading)
                }
            }

            Section("Transaktionen") {
                if model.transactions.isEmpty {
                    Text("Keine Transaktionen im gewählten Analysebereich gefunden.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.transactions) { transaction in
                        transactionRow(transaction)
                    }
                }
            }
        }
        .financeFormStyle()
    }

    private func transactionRow(_ transaction: Transaction) -> some View {
        HStack(spacing: AppSpacing.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.effectiveMerchantName)
                    .lineLimit(1)
                Text("\(AppDateFormatter.day(transaction.displayDate)) · \(transaction.source.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: AppSpacing.m)
            Text(transactionAmountText(transaction.amount))
                .font(.callout.monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(transaction.effectiveMerchantName), \(AppDateFormatter.day(transaction.displayDate)), \(PrivacyAwareMoney.accessibilityLabel(transaction.amount, privacy: privacyState, signed: true))"
        )
    }

    private func amountText(_ amount: Decimal) -> String {
        guard !privacyState.hidesAmounts else { return String(localized: "Betrag verborgen") }
        return PrivacyAwareMoney.decimalString(
            amount,
            currency: model.currency,
            privacy: privacyState
        )
    }

    private func transactionAmountText(_ amount: Money) -> String {
        guard !privacyState.hidesAmounts else { return String(localized: "Betrag verborgen") }
        return PrivacyAwareMoney.signed(amount, privacy: privacyState)
    }
}
