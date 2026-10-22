import SwiftUI

struct ReviewQueueView: View {
    @State private var model: ReviewQueueModel
    @Environment(\.dismiss) private var dismiss
    let showsDismissButton: Bool

    init(dependencies: AppDependencies, showsDismissButton: Bool = true) {
        _model = State(initialValue: ReviewQueueModel(dependencies: dependencies))
        self.showsDismissButton = showsDismissButton
    }

    var body: some View {
        AdaptiveSheet(title: String(localized: "Prüfliste")) {
            Group {
                if let error = model.errorMessage, model.items.isEmpty && !model.isLoading {
                    ErrorStateView(message: error) {
                        Task { await model.load() }
                    }
                } else if model.isLoading, model.items.isEmpty {
                    LoadingStateView()
                } else if model.items.isEmpty {
                    EmptyStateView(
                        title: String(localized: "Alles geprüft"),
                        message: String(localized: "Aktuell gibt es nichts zu prüfen. Neue Buchungen ohne Kategorie oder mit Auffälligkeiten erscheinen hier."),
                        systemImage: "checkmark.seal.fill",
                        tint: AppPalette.positive
                    )
                } else {
                    reviewList
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                }
            }
        }
        .accessibilityIdentifier("screen-ready-review")
        .task { await model.load() }
        .sheet(item: $model.categoryCreationRequest) { request in
            CategoryEditorSheet(
                dependencies: model.dependenciesForCategoryEditor,
                editing: nil,
                onSaved: {},
                onCreated: { category in
                    Task { await model.categoryCreated(category, for: request) }
                },
                suggestedName: request.suggestedName,
                suggestedParentID: request.suggestedParentID
            )
        }
    }

    private var reviewList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.l) {
                overview

                if let error = model.errorMessage {
                    HStack(spacing: AppSpacing.m) {
                        InlineNotice(message: error, tone: .warning)
                        Button("Erneut versuchen") {
                            Task { await model.load() }
                        }
                        .controlSize(.small)
                    }
                }

                reviewSection(
                    action: .categorize,
                    title: String(localized: "Kategorisieren"),
                    subtitle: String(localized: "Eine Auswahl kann als Regel für ähnliche Händler gespeichert werden."),
                    systemImage: "tag.fill",
                    color: AppPalette.warning
                )
                reviewSection(
                    action: .confirmTransfer,
                    title: String(localized: "Transfers prüfen"),
                    subtitle: String(localized: "Bestätigte Paare werden als interne Umbuchungen behandelt."),
                    systemImage: "arrow.left.arrow.right",
                    color: AppPalette.information
                )
                reviewSection(
                    action: .complete,
                    title: String(localized: "Weitere Hinweise"),
                    subtitle: String(localized: "Prüfe Händler- und Währungsangaben und schließe den Vorgang ab."),
                    systemImage: "checkmark",
                    color: AppPalette.positive
                )
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.l)
        }
        .background(AppPalette.canvas)
        .accessibilityIdentifier("review-queue-list")
    }

    private var overview: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.m) {
            Text("\(model.entries.count)")
                .font(AppTypography.largeMetric)
                .monospacedDigit()
                .foregroundStyle(AppPalette.warning)
            VStack(alignment: .leading, spacing: 1) {
                (model.entries.count == 1 ? Text("Transaktion offen") : Text("Transaktionen offen"))
                    .font(.headline)
                Text(reviewSummaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var reviewSummaryText: String {
        let issueCount = model.items.count
        let base = issueCount == model.entries.count
            ? String(localized: "Transaktionen warten auf deine Entscheidung.")
            : String(localized: "\(issueCount) Hinweise sind in eindeutigen Transaktionen gebündelt.")
        let suggested = model.suggestedCategorizeEntries.count
        guard suggested > 0 else { return base }
        return base + " " + String(localized: "Davon \(suggested) mit Kategorie-Vorschlag.")
    }

    @ViewBuilder
    private func reviewSection(
        action: ReviewQueueEntry.PrimaryAction,
        title: String,
        subtitle: String,
        systemImage: String,
        color: Color
    ) -> some View {
        let entries = model.entries(for: action)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.m) {
                HStack(alignment: .center, spacing: AppSpacing.m) {
                    IconTile(systemName: systemImage, color: color, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(title) · \(entries.count)")
                            .font(AppTypography.sectionTitle)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: AppSpacing.s)
                    if action == .categorize, model.isAdvising {
                        HStack(spacing: AppSpacing.xs) {
                            ProgressView().controlSize(.small)
                            Text("Vorschläge werden ermittelt …")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if action == .categorize {
                        let suggested = model.bulkAcceptableEntries
                        if !suggested.isEmpty {
                            Button {
                                Task { await model.acceptAllSuggestions() }
                            } label: {
                                Label(
                                    "Alle Vorschläge (\(suggested.count)) übernehmen",
                                    systemImage: "wand.and.stars"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityLabel(
                                "Alle \(suggested.count) Kategorie-Vorschläge übernehmen, inklusive Händler-Regeln"
                            )
                            .accessibilityHint(
                                "Jeder Vorschlag legt zugleich eine Händler-Regel an, sodass ähnliche Buchungen künftig automatisch kategorisiert werden."
                            )
                        }
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        reviewRow(entry)
                            .padding(.vertical, AppSpacing.s)
                    }
                }
                .padding(.horizontal, AppSpacing.l)
                .padding(.vertical, AppSpacing.xs)
                .appSurface(.groupedContent)
            }
        }
    }

    private func reviewRow(_ entry: ReviewQueueEntry) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.m) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(entry.transaction.effectiveMerchantName)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    Text("\(AppDateFormatter.day(entry.transaction.displayDate)) · \(model.accountName(for: entry.transaction))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    reasonLine(entry.reasons)

                    if let description = entry.transaction.rawDescription,
                       !description.isEmpty,
                       description.localizedCaseInsensitiveCompare(entry.transaction.effectiveMerchantName) != .orderedSame {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: AppSpacing.s)

                MoneyText(money: entry.transaction.amount, signed: true)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppSpacing.s) {
                    contextualHint(for: entry)
                    Spacer(minLength: AppSpacing.s)
                    actionBar(for: entry)
                }
                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    contextualHint(for: entry)
                    // Knöpfe bleiben nebeneinander, nur der Hinweis rückt
                    // in schmalen Fenstern darüber.
                    HStack(spacing: AppSpacing.s) {
                        actionBar(for: entry)
                    }
                }
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .opacity(model.isProcessing(entry) ? 0.65 : 1)
    }

    private func reasonLine(_ reasons: [ReviewItem.Reason]) -> some View {
        HStack(spacing: AppSpacing.m) {
            ForEach(reasons, id: \.self) { reason in
                Label(title(for: reason), systemImage: icon(for: reason))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func contextualHint(for entry: ReviewQueueEntry) -> some View {
        if entry.primaryAction == .categorize {
            let similarCount = model.similarUncategorizedCount(for: entry)
            if similarCount > 1 {
                Label(
                    "\(similarCount) ähnliche offene Transaktionen",
                    systemImage: "rectangle.stack"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(similarCount) ähnliche Transaktionen können gemeinsam kategorisiert werden")
            } else {
                Text("Kategorie auswählen und künftig automatisch zuordnen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let categoryName = model.categoryName(for: entry.transaction) {
            Label(categoryName, systemImage: "tag")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actionBar(for entry: ReviewQueueEntry) -> some View {
        switch entry.primaryAction {
        case .categorize:
            if let (category, supportCount) = model.suggestionCategory(for: entry) {
                Button {
                    Task { await model.acceptSuggestion(entry) }
                } label: {
                    // Ohne Verlauf stammt der Vorschlag aus dem Händlernamen.
                    Label(
                        "Vorschlag: \(category.name)",
                        systemImage: supportCount > 0 ? "wand.and.stars" : "sparkles"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isProcessing(entry))
                .help(supportCount > 0
                    ? (supportCount == 1
                        ? String(localized: "So hast du eine ähnliche Buchung eingeordnet.")
                        : String(localized: "So hast du \(supportCount) ähnliche Buchungen eingeordnet."))
                    : String(localized: "Aus dem Händlernamen erkannt."))
                .accessibilityLabel(
                    supportCount > 0
                        ? String(localized: "Vorschlag übernehmen: \(category.name), gestützt durch \(supportCount) Buchungen")
                        : String(localized: "Vorschlag übernehmen: \(category.name), aus dem Händlernamen gelesen")
                )
                .accessibilityHint(
                    model.canRememberMerchant(for: entry)
                        ? String(localized: "Übernimmt die Kategorie und legt zugleich eine Händler-Regel an. Ähnliche Buchungen werden mitgeprüft.")
                        : String(localized: "Übernimmt die Kategorie für diese Transaktion.")
                )
                categoryMenu(for: entry, label: "Andere…")
            } else if let proposal = model.newCategoryProposal(for: entry) {
                Button {
                    model.requestCategoryCreation(for: entry, suggestedName: proposal.name, suggestedParentID: proposal.parentID)
                } label: {
                    Label("Neue Kategorie: \(proposal.name)", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isProcessing(entry))
                .help("Vorschlag aus dem Händlernamen. Du kannst Name und Einordnung vor dem Anlegen ändern.")
                .accessibilityLabel("Neue Kategorie \(proposal.name) anlegen und zuordnen")
                categoryMenu(for: entry, label: "Andere…")
            } else {
                categoryMenu(for: entry)
                    .buttonStyle(.borderedProminent)
            }

        case .confirmTransfer:
            Button {
                Task {
                    await model.markAsTransfer(
                        entry.item(for: .possibleTransfer),
                        linkedTransactionID: entry.linkedTransactionID
                    )
                }
            } label: {
                Label("Transfer bestätigen", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Als internen Transfer bestätigen")

        case .complete:
            Button {
                Task { await model.markReviewed(entry.item()) }
            } label: {
                Label("Prüfung abschließen", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Prüfung abschließen und aus der Liste entfernen")
        }

        if entry.primaryAction != .complete {
            Menu {
                Button {
                    Task { await model.markReviewed(entry.item()) }
                } label: {
                    Label("Ohne weitere Änderung abschließen", systemImage: "checkmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Weitere Aktionen für \(entry.transaction.effectiveMerchantName)")
            .help("Weitere Aktionen")
        }

        if model.isProcessing(entry) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Änderung wird gespeichert")
        }
    }

    private func categoryMenu(for entry: ReviewQueueEntry, label: LocalizedStringKey = "Kategorie wählen") -> some View {
        Menu {
            Button("Neue Kategorie …") {
                model.requestCategoryCreation(for: entry)
            }
            Divider()
            if model.canRememberMerchant(for: entry) {
                Section("Für diesen Händler merken") {
                    categoryOptions(for: entry, scope: .merchant)
                }

                Menu("Nur diese Transaktion") {
                    categoryOptions(for: entry, scope: .transactionOnly)
                }
            } else {
                Section("Nur diese Transaktion") {
                    categoryOptions(for: entry, scope: .transactionOnly)
                }
            }
        } label: {
            Label(label, systemImage: "tag")
        }
        .controlSize(.small)
        .disabled(model.assignableCategories.isEmpty || model.isProcessing(entry))
        .accessibilityLabel("Kategorie für \(entry.transaction.effectiveMerchantName) wählen")
        .accessibilityHint(
            model.canRememberMerchant(for: entry)
                ? String(localized: "Die erste Auswahl speichert zugleich eine Regel für diesen Händler.")
                : String(localized: "Die Auswahl gilt für diese Transaktion.")
        )
    }

    @ViewBuilder
    private func categoryOptions(
        for entry: ReviewQueueEntry,
        scope: ReviewQueueModel.CategoryAssignmentScope
    ) -> some View {
        ForEach(model.categoryGroups) { group in
            Menu {
                ForEach(group.categories) { category in
                    categoryButton(category, for: entry, scope: scope)
                }
            } label: {
                Label(group.parent.name, systemImage: group.parent.systemIconName)
            }
        }

        ForEach(model.standaloneCategories) { category in
            categoryButton(category, for: entry, scope: scope)
        }
    }

    private func categoryButton(
        _ category: Category,
        for entry: ReviewQueueEntry,
        scope: ReviewQueueModel.CategoryAssignmentScope
    ) -> some View {
        Button {
            Task {
                await model.assignCategory(
                    entry.item(for: .uncategorized),
                    categoryID: category.id,
                    scope: scope
                )
            }
        } label: {
            Label(category.name, systemImage: category.systemIconName)
        }
    }

    private func title(for reason: ReviewItem.Reason) -> LocalizedStringKey {
        switch reason {
        case .uncategorized: "Ohne Kategorie"
        case .unknownMerchant: "Händler unbekannt"
        case .possibleTransfer: "Möglicher Transfer"
        case .foreignCurrency: "Fremdwährung"
        }
    }

    private func icon(for reason: ReviewItem.Reason) -> String {
        switch reason {
        case .uncategorized: "tag.slash"
        case .unknownMerchant: "questionmark.circle"
        case .possibleTransfer: "arrow.left.arrow.right"
        case .foreignCurrency: "dollarsign.circle"
        }
    }
}
