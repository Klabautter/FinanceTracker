import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @State private var model: ImportModel
    @State private var showsFileImporter = false
    @State private var rollbackBatchID: UUID?
    @State private var showsAllIssues = false
    /// „Letzte Imports" zeigt zunächst nur die neuesten Einträge.
    @State private var showsAllBatches = false
    private static let collapsedBatchCount = 5

    @State private var newAccountName = ""
    @State private var mapDate = ""
    @State private var mapAmount = ""
    @State private var mapDescription = ""
    @State private var mapMerchant = ""
    @State private var mapCurrency = ""
    @State private var mapExternalID = ""
    @Environment(PrivacyPresentationState.self) private var privacyState

    init(dependencies: AppDependencies) {
        _model = State(initialValue: ImportModel(dependencies: dependencies))
    }

    var body: some View {
        Form {
            accountSection
            fileSection
            resultSection
            historySection
            hintSection
        }
        .financeFormStyle()
        .navigationTitle("Import")
        .accessibilityIdentifier("screen-ready-import")
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: Self.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    model.fileSelectionFailed()
                    return
                }
                Task { await model.prepareFile(at: url) }
            case .failure:
                model.fileSelectionFailed()
            }
        }
        .alert(
            "Import rückgängig machen?",
            isPresented: Binding(
                get: { rollbackBatchID != nil },
                set: { if !$0 { rollbackBatchID = nil } }
            )
        ) {
            Button("Rückgängig machen", role: .destructive) {
                guard let batchID = rollbackBatchID else { return }
                rollbackBatchID = nil
                Task { await model.rollback(batchID: batchID) }
            }
            Button("Abbrechen", role: .cancel) {
                rollbackBatchID = nil
            }
        } message: {
            Text("Neu importierte Transaktionen werden gelöscht und durch diesen Import aktualisierte Buchungen auf ihren vorherigen Stand zurückgesetzt.")
        }
        .task {
            await model.loadAccounts()
            await model.loadHistory()
        }
    }

    private static let supportedContentTypes: [UTType] = {
        var types: [UTType] = [.commaSeparatedText, .text, .pdf]
        if let xlsx = UTType(filenameExtension: "xlsx") {
            types.append(xlsx)
        }
        return types
    }()

    private var accountSection: some View {
        Section("Ziel-Konto") {
            Picker("Konto", selection: Binding(
                get: { model.selectedAccountID ?? model.accounts.first?.id },
                set: { model.selectedAccountID = $0 }
            )) {
                ForEach(model.accounts) { account in
                    Text(account.hasExternalIdentifier ? "\(account.name) · \(account.presentationIdentifier)" : account.name)
                        .tag(Optional(account.id))
                }
            }
            .accessibilityLabel("Zielkonto für den Import wählen")
            .disabled(!model.canChangeTargetAccount)
            if model.canChangeTargetAccount, model.phase != .needsAccount(suggestedName: "") {
                newAccountRow(buttonTitle: "Konto anlegen") { name in
                    await model.createAccount(named: name)
                }
            }
        }
    }

    /// Neues Zielkonto direkt beim Import anlegen (z. B. für eine Bank, die
    /// noch kein Konto in der App hat).
    private func newAccountRow(buttonTitle: LocalizedStringKey, create: @escaping (String) async -> Void) -> some View {
        HStack(spacing: AppSpacing.s) {
            TextField("Neues Konto", text: $newAccountName, prompt: Text("Name, z. B. deiner Bank"))
                .accessibilityLabel("Name des neuen Kontos")
                .onSubmit { submitNewAccount(create) }
            Button(buttonTitle) { submitNewAccount(create) }
                .disabled(newAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submitNewAccount(_ create: @escaping (String) async -> Void) {
        let name = newAccountName
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        newAccountName = ""
        Task { await create(name) }
    }

    @ViewBuilder
    private var fileSection: some View {
        Section("Datei") {
            switch model.phase {
            case .idle:
                selectFileButton(title: "CSV, Excel oder PDF auswählen…")
                    .keyboardShortcut("i", modifiers: [.command])

            case .running:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Import läuft…")
                }

            case .reviewing(let fileName, let providerName):
                reviewContent(fileName: fileName, providerName: providerName)

            case .needsAccount:
                Text("Für diese Datei gibt es noch kein Konto. Lege eines an, dann geht der Import weiter.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                newAccountRow(buttonTitle: "Konto anlegen und fortfahren") { name in
                    await model.createAccountAndContinue(named: name)
                }
                Button("Abbrechen") {
                    model.reset()
                }

            case .needsMapping:
                mappingContent

            default:
                selectFileButton(title: "Neue Datei auswählen…")
            }
        }
    }

    private var mappingContent: some View {
        Group {
            Text("Spalten konnten nicht automatisch erkannt werden. Bitte zuordnen:")
                .font(.callout)
                .foregroundStyle(.secondary)

            columnPicker("Datums-Spalte *", selection: $mapDate, allowsEmpty: true, placeholder: "Bitte auswählen")
            columnPicker("Betrag-Spalte *", selection: $mapAmount, allowsEmpty: true, placeholder: "Bitte auswählen")
            columnPicker("Beschreibung", selection: $mapDescription, allowsEmpty: true)
            columnPicker("Händler", selection: $mapMerchant, allowsEmpty: true)
            columnPicker("Währung", selection: $mapCurrency, allowsEmpty: true)
            columnPicker("Referenz-ID", selection: $mapExternalID, allowsEmpty: true)

            HStack {
                Button {
                    Task {
                        await model.applyManualMapping(
                            dateColumn: mapDate,
                            amountColumn: mapAmount,
                            descriptionColumn: optionalColumn(mapDescription),
                            merchantColumn: optionalColumn(mapMerchant),
                            currencyColumn: optionalColumn(mapCurrency),
                            externalIDColumn: optionalColumn(mapExternalID)
                        )
                    }
                } label: {
                    Label("Vorschau erzeugen", systemImage: "tablecells")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isMappingValid)

                Button("Abbrechen") {
                    resetMappingSelections()
                    model.reset()
                }
            }
        }
    }

    private func columnPicker(
        _ title: LocalizedStringKey,
        selection: Binding<String>,
        allowsEmpty: Bool = false,
        placeholder: LocalizedStringKey? = nil
    ) -> some View {
        Picker(title, selection: selection) {
            if let placeholder {
                Text(placeholder).tag("")
            } else if allowsEmpty {
                Text("– keine –").tag("")
            }
            ForEach(model.mappingHeaders, id: \.self) { header in
                Text(header).tag(header)
            }
        }
    }

    private var isMappingValid: Bool {
        let date = mapDate
        let amount = mapAmount
        guard !date.isEmpty, !amount.isEmpty else { return false }
        guard date != amount else { return false }
        return true
    }

    private func optionalColumn(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func resetMappingSelections() {
        mapDate = ""
        mapAmount = ""
        mapDescription = ""
        mapMerchant = ""
        mapCurrency = ""
        mapExternalID = ""
    }

    private func selectFileButton(title: LocalizedStringKey) -> some View {
        Button {
            showsFileImporter = true
        } label: {
            Label(title, systemImage: "folder.badge.plus")
        }
    }

    @ViewBuilder
    private func reviewContent(fileName: String?, providerName: String) -> some View {
        if let prepared = model.preparedImport {
            LabeledContent("Datei", value: fileName ?? "–")
            LabeledContent("Importziel", value: model.preparedTargetAccountName ?? String(localized: "Konto nicht verfügbar"))
            LabeledContent("Zeilen in der Datei", value: "\(prepared.totalRows)")
            LabeledContent("Neue Transaktionen", value: "\(prepared.transactions.count)")
            if !prepared.updates.isEmpty {
                LabeledContent("Pending → Gebucht", value: "\(prepared.updates.count)")
            }
            // Konsistent mit ImportResult.summaryMessage (#5): identisches Label.
            LabeledContent(ImportResult.duplicateLabel, value: "\(prepared.duplicateCount)")
            if !prepared.crossSourceDuplicates.isEmpty {
                LabeledContent("Bereits vorhanden (andere Quelle)", value: "\(prepared.crossSourceDuplicates.count)")
            }
            if prepared.failedCount > 0 {
                LabeledContent("Nicht importierbare Zeilen", value: "\(prepared.failedCount)")
            }
            if prepared.isExactFileReplay {
                Label(
                    ImportDedupNotices.fileReplayDetail,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(AppPalette.warning)
                .accessibilityLabel(ImportDedupNotices.fileAlreadyImported)
            }

            // Die Bestätigung steht direkt unter der Zusammenfassung; unter der
            // Vorschau lag sie außerhalb des sichtbaren Bereichs.
            HStack {
                Button {
                    Task { await model.confirmImport() }
                } label: {
                    Label(
                        "\(prepared.transactions.count + prepared.updates.count) Änderungen übernehmen",
                        systemImage: "checkmark.circle.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(prepared.transactions.isEmpty && prepared.updates.isEmpty)
                .accessibilityLabel(
                    "Import bestätigen: \(prepared.transactions.count) neue Transaktionen und \(prepared.updates.count) Aktualisierungen"
                )

                Button("Andere Datei") {
                    model.reset()
                }
            }

            previewTable(prepared)

            if !prepared.crossSourceDuplicates.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    Label(
                        prepared.crossSourceDuplicates.count == 1
                            ? String(localized: "1 Buchung liegt schon aus einer anderen Quelle auf dem Konto und wird übersprungen")
                            : String(localized: "\(prepared.crossSourceDuplicates.count) Buchungen liegen schon aus einer anderen Quelle auf dem Konto und werden übersprungen"),
                        systemImage: "doc.on.doc"
                    )
                    .font(.subheadline.weight(.medium))

                    DisclosureGroup("Übersprungene Buchungen anzeigen") {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(prepared.crossSourceDuplicates, id: \.self) { issue in
                                Text(issue.displayMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    Button("Trotzdem importieren") {
                        Task { await model.includeCrossSourceDuplicates() }
                    }
                    .accessibilityHint("Importiert auch die Buchungen, die schon aus einer anderen Quelle vorhanden sind")
                }
                .padding(.vertical, 4)
            }

            if !prepared.crossSourceHints.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    Label(
                        "\(prepared.crossSourceHints.count) mögliche Doppelbuchungen aus anderer Quelle (kein automatischer Abgleich)",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppPalette.warning)
                    .accessibilityLabel("Mögliche Doppelbuchungen aus anderer Quelle zur Prüfung")

                    ForEach(prepared.crossSourceHints, id: \.self) { hint in
                        Text(hint.displayMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }

            if !prepared.issues.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    Label(prepared.issues.count == 1 ? String(localized: "1 Zeile braucht Aufmerksamkeit") : String(localized: "\(prepared.issues.count) Zeilen brauchen Aufmerksamkeit"), systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppPalette.warning)

                    DisclosureGroup("Alle Zeilenhinweise anzeigen", isExpanded: $showsAllIssues) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(prepared.issues, id: \.self) { issue in
                                Text(issue.displayMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

        }
    }

    @ViewBuilder
    private func previewTable(_ prepared: PreparedImport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Vorschau")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if !prepared.transactions.isEmpty {
                previewRows(
                    prepared.transactions,
                    title: String(localized: "Neue Buchungen"),
                    changeDescription: String(localized: "Wird neu importiert")
                )
            }

            if !prepared.updates.isEmpty {
                previewRows(
                    prepared.updates,
                    title: String(localized: "Aktualisierungen"),
                    changeDescription: String(localized: "Pending wird als gebucht aktualisiert")
                )
            }
        }
        .padding(.vertical, 6)
    }

    private func previewRows(
        _ transactions: [Transaction],
        title: String,
        changeDescription: String
    ) -> some View {
        let sorted = transactions.sorted { $0.displayDate > $1.displayDate }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(title) (\(transactions.count))")
                .font(.caption.weight(.semibold))
            ForEach(sorted.prefix(50)) { txn in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(txn.effectiveMerchantName)
                            .lineLimit(1)
                        Text("\(AppDateFormatter.day(txn.displayDate)) · \(changeDescription)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: AppSpacing.s)
                    if let cashback = txn.cashbackAmount, let currency = txn.cashbackCurrency {
                        Text("+\(PrivacyAwareMoney.string(Money(amount: cashback, currency: currency), privacy: privacyState))")
                            .font(.caption2)
                            .foregroundStyle(AppPalette.positive)
                    }
                    MoneyText(money: txn.amount, signed: true)
                        .font(.callout)
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
                Divider()
            }
            if transactions.count > 50 {
                Text("… und \(transactions.count - 50) weitere")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch model.phase {
        case .completed(let result):
            Section("Ergebnis") {
                LabeledContent("Datensätze", value: "\(result.totalRows)")
                LabeledContent("Importiert", value: "\(result.importedCount)")
                if result.updatedCount > 0 {
                    LabeledContent("Aktualisiert (Pending→Booked)", value: "\(result.updatedCount)")
                }
                // Konsistent mit ImportResult.summaryMessage (#5).
                LabeledContent(ImportResult.duplicateLabel, value: "\(result.duplicateCount)")
                if result.failedCount > 0 {
                    LabeledContent("Fehlgeschlagen", value: "\(result.failedCount)")
                }
                if result.crossSourceDuplicateCount > 0 {
                    LabeledContent("Bereits vorhanden (andere Quelle)", value: "\(result.crossSourceDuplicateCount)")
                }
                if result.crossSourceHintCount > 0 {
                    LabeledContent("Prüfhinweise (andere Quelle)", value: "\(result.crossSourceHintCount)")
                }
                if result.isExactFileReplay {
                    Label(
                        ImportDedupNotices.fileAlreadyImported,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(AppPalette.warning)
                    .accessibilityLabel(ImportDedupNotices.fileAlreadyImported)
                }

                if let batchID = model.lastCompletedBatchID {
                    Button(role: .destructive) {
                        rollbackBatchID = batchID
                    } label: {
                        Label("Diesen Import rückgängig machen", systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(model.isRollingBack)
                    .accessibilityLabel("Zuletzt importierte Transaktionen wieder löschen")
                }
            }
        case .failed(let message):
            Section {
                Text(message)
                    .foregroundStyle(AppPalette.critical)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !model.recentBatches.isEmpty {
            Section("Letzte Imports") {
                ForEach(showsAllBatches ? model.recentBatches : Array(model.recentBatches.prefix(Self.collapsedBatchCount))) { batch in
                    historyRow(batch)
                }
                if model.recentBatches.count > Self.collapsedBatchCount {
                    Button(showsAllBatches
                        ? String(localized: "Nur die neuesten anzeigen")
                        : String(localized: "Alle \(model.recentBatches.count) Imports anzeigen")) {
                        showsAllBatches.toggle()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("import-history-toggle")
                }
            }
        }
    }

    private func historyRow(_ batch: ImportBatch) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppDateFormatter.day(batch.completedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(model.displayName(forProviderIdentifier: batch.providerIdentifier))
                    .font(.callout.weight(.medium))
                if let fileName = batch.fileName {
                    Text(fileName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(summaryLine(for: batch))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                rollbackBatchID = batch.id
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.title3)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(model.isRollingBack)
            .accessibilityLabel("Diesen Import rückgängig machen")
            .help("Diesen Import rückgängig machen")
        }
        .padding(.vertical, 2)
    }

    private func summaryLine(for batch: ImportBatch) -> String {
        var parts = [String(localized: "\(batch.importedCount) importiert")]
        if batch.updatedCount > 0 { parts.append(String(localized: "\(batch.updatedCount) aktualisiert")) }
        if batch.duplicateCount > 0 { parts.append(String(localized: "\(batch.duplicateCount) Duplikate")) }
        if batch.failedCount > 0 { parts.append(String(localized: "\(batch.failedCount) Fehler")) }
        return parts.joined(separator: " · ")
    }

    private var hintSection: some View {
        Section("Unterstützte Formate") {
            Text("CSV- und Excel-Dateien sowie PDF-Kontoauszüge mit einer Datums- und einer Betragsspalte, egal von welcher Bank oder Karte. Die Spalten werden automatisch erkannt; gelingt das nicht, kannst du sie zuordnen. Bereits vorhandene Buchungen werden übersprungen, Kategorien über deine Regeln zugewiesen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(ImportDedupNotices.differentAccountHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Hinweis zur konto-scharfen Duplikaterkennung")
            Text("Gleiche Buchungen aus CSV und Open Banking werden nicht automatisch zusammengeführt, sondern als mögliche Doppelbuchung zur Prüfung markiert.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
