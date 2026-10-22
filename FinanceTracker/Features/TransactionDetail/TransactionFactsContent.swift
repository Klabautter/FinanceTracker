import SwiftUI

/// Kanonische Darstellung der Transaktionsfakten (P1 UX).
///
/// Reine Darstellung, keine Business-Logik: Alle Edit-Aktionen
/// (Kategorie-Picker, Tag-Toggle, Geprüft, Ausschließen) laufen über die
/// Callbacks ins Model. Wird im Inspector UND im Sheet verwendet,
/// `TransactionDetailView` bettet diese Komponente ein, das Sheet ruft
/// dieselbe `TransactionDetailView` auf (kein Duplikat).
struct TransactionFactsContent: View {
    let txn: Transaction
    let category: Category?
    let assignableCategories: [Category]
    let accountName: String?
    let allTags: [Tag]

    var onAssignCategory: (UUID?, Bool) -> Void
    /// Öffnet die Neuanlage einer Kategorie für diese Buchung.
    var onCreateCategory: (() -> Void)? = nil
    var onToggleTag: (UUID) -> Void
    var onToggleReviewed: (Bool) -> Void
    var onToggleExcluded: (Bool) -> Void
    /// Speichert die Notiz (leer = entfernen). Ohne Callback nur Anzeige.
    var onUpdateNote: ((String?) -> Void)? = nil
    /// Zusatz direkt unter der Kategorie-Zeile, z. B. die Rückfrage, ob eine
    /// Änderung für alle Buchungen des Händlers gelten soll.
    var categoryFooter: AnyView?

    @Environment(PrivacyPresentationState.self) private var privacyState
    @State private var remembersMerchant = true
    @State private var showsTechnicalDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            header

            factsCard {
                categoryPicker
                if let categoryFooter {
                    categoryFooter
                        .padding(.vertical, AppSpacing.s)
                }
                if txn.isUnlinkedOwnTransfer {
                    Label(
                        txn.amount.isNegative
                            ? String(localized: "Geht an ein eigenes Konto, das nicht in der App ist. Zählt als Ausgabe, bis du das Konto hinzufügst. Dann wird die Umbuchung verknüpft.")
                            : String(localized: "Kommt von einem eigenen Konto, das nicht in der App ist. Zählt als Einnahme, bis du das Konto hinzufügst. Dann wird die Umbuchung verknüpft."),
                        systemImage: "arrow.left.arrow.right"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, AppSpacing.s)
                }
                cardDivider
                factRow("Datum", AppDateFormatter.day(txn.displayDate))
                if let accountName {
                    cardDivider
                    factRow("Konto", accountName)
                }
                cardDivider
                factRow("Typ", txn.kind.displayName)
                if let paymentMethod = txn.paymentMethod {
                    cardDivider
                    factRow("Zahlungsart", paymentMethod.displayName)
                }
                if let asset = txn.cryptoAsset, let cryptoAmount = txn.cryptoAmount {
                    cardDivider
                    factRow("Krypto-Betrag", "\(cryptoAmount.description) \(asset)")
                }
                if let originalAmount = txn.originalAmount,
                   let originalCurrency = txn.originalCurrency {
                    cardDivider
                    factRow(
                        "Originalbetrag",
                        PrivacyAwareMoney.decimalString(originalAmount, currency: originalCurrency, privacy: privacyState)
                    )
                }
                if let cashbackAmount = txn.cashbackAmount, let cashbackCurrency = txn.cashbackCurrency {
                    cardDivider
                    factRow(
                        "Cashback",
                        "+" + PrivacyAwareMoney.string(Money(amount: cashbackAmount, currency: cashbackCurrency), privacy: privacyState),
                        valueColor: AppPalette.positive
                    )
                }
            }

            if let onUpdateNote {
                factsCard {
                    TransactionNoteEditor(note: txn.note, onCommit: onUpdateNote)
                        .id(txn.id)
                        .padding(.vertical, 6)
                }
            } else if let note = txn.note, !note.isEmpty {
                factsCard {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Notiz").eyebrowStyle()
                        Text(note)
                            .font(.callout)
                    }
                    .padding(.vertical, 6)
                }
            }

            factsCard {
                tagsSection
            }

            factsCard {
                Toggle(isOn: Binding(
                    get: { txn.reviewed },
                    set: { onToggleReviewed($0) }
                )) {
                    Label("Geprüft", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .padding(.vertical, 6)
                .accessibilityLabel(txn.reviewed ? Text("Als ungeprüft markieren") : Text("Als geprüft markieren"))
                cardDivider
                Toggle(isOn: Binding(
                    get: { txn.excludedFromAnalytics },
                    set: { onToggleExcluded($0) }
                )) {
                    Label("Aus Analyse ausschließen", systemImage: "eye.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .padding(.vertical, 6)
                .accessibilityLabel(txn.excludedFromAnalytics ? Text("In Analyse einschließen") : Text("Aus Analyse ausschließen"))
            }

            // macOS 26: DisclosureGroup combined with selectable fact labels caused
            // recursive accessibility label resolution and a crash. Keep expansion explicit.
            Button {
                showsTechnicalDetails.toggle()
            } label: {
                Label("Technische Details", systemImage: showsTechnicalDetails ? "chevron.down" : "chevron.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, AppSpacing.xs)
            .accessibilityValue(showsTechnicalDetails ? Text("Ausgeklappt") : Text("Eingeklappt"))
            .accessibilityIdentifier("transaction-technical-details")

            if showsTechnicalDetails {
                factsCard {
                    factRow("Quelle", txn.source.displayName)
                    if let externalID = txn.externalID {
                        cardDivider
                        factRow("Provider-ID", externalID)
                    }
                    if let rawDescription = txn.rawDescription {
                        cardDivider
                        factRow("Originalbeschreibung", rawDescription)
                    }
                    if let fingerprint = txn.sourceFingerprint {
                        cardDivider
                        HStack(alignment: .top) {
                            Text("Fingerprint")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(fingerprint.prefix(16) + "…")
                                .font(.caption.monospaced())
                                .accessibilityLabel("Fingerprint der Transaktion")
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: AppSpacing.m) {
            IconTile(
                systemName: category?.systemIconName ?? "questionmark",
                color: category?.colorToken.color ?? .gray,
                size: 46
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(txn.effectiveMerchantName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text("\(AppDateFormatter.day(txn.displayDate)) · \(category?.name ?? String(localized: "Ohne Kategorie"))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: AppSpacing.s)
            VStack(alignment: .trailing, spacing: 4) {
                MoneyText(money: txn.amount, signed: true)
                    .font(AppTypography.largeMetric)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
                statusBadge(for: txn.status)
            }
        }
        .padding(.bottom, AppSpacing.xs)
    }

    private func factsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, AppSpacing.l)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.groupedContent, cornerRadius: AppRadius.card)
    }

    private var cardDivider: some View {
        Divider()
    }

    private func factRow(_ label: LocalizedStringKey, _ value: String, valueColor: Color = .primary) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.m) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: AppSpacing.s)
            Text(value)
                .font(.callout)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categoryPicker: some View {
        HStack(spacing: AppSpacing.m) {
            Text("Kategorie")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: AppSpacing.s)

            Menu {
                Toggle("Für diesen Händler merken", isOn: $remembersMerchant)
                Divider()
                Button("Ohne Kategorie") {
                    onAssignCategory(nil, false)
                }
                if let onCreateCategory {
                    Button("Neue Kategorie …", action: onCreateCategory)
                }
                Divider()
                ForEach(assignableCategories) { category in
                    Button {
                        onAssignCategory(category.id, remembersMerchant)
                    } label: {
                        Label(category.name, systemImage: category.systemIconName)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if let category {
                        IconTile(systemName: category.systemIconName, color: category.colorToken.color, size: 20)
                        Text(category.name)
                    } else {
                        Text("Kategorie wählen")
                            .foregroundStyle(AppPalette.warning)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            // Eigener Doppelpfeil im Label, der Standard-Pfeil wäre doppelt.
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Kategorie für \(txn.effectiveMerchantName) ändern")

        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assignedTagIDs: Set<UUID> {
        Set(txn.tagIDs ?? [])
    }

    @ViewBuilder
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Tags")
                .eyebrowStyle()
                .padding(.top, 8)
            if allTags.isEmpty {
                if assignedTagIDs.isEmpty {
                    Text("Noch keine Tags")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(allTags.filter { assignedTagIDs.contains($0.id) }) { tag in
                            TagChip(tag: tag)
                        }
                    }
                }
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(allTags) { tag in
                        let isAssigned = assignedTagIDs.contains(tag.id)
                        Button {
                            onToggleTag(tag.id)
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(tag.colorToken.color).frame(width: 7, height: 7)
                                Text(tag.name)
                                if isAssigned {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                }
                            }
                            .font(.callout)
                            .foregroundStyle(isAssigned ? tag.colorToken.color : Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(isAssigned ? tag.colorToken.color.opacity(0.15) : Color.primary.opacity(0.05)))
                            .overlay(Capsule().strokeBorder(isAssigned ? tag.colorToken.color.opacity(0.4) : Color.clear))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isAssigned ? Text("Tag entfernen: \(tag.name)") : Text("Tag zuweisen: \(tag.name)"))
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusBadge(for status: TransactionStatus) -> some View {
        Text(status.displayName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(statusColor(for: status).opacity(0.15)))
            .foregroundStyle(statusColor(for: status))
    }

    private func statusColor(for status: TransactionStatus) -> Color {
        switch status {
        case .pending: AppPalette.warning
        case .booked: AppPalette.positive
        case .reversed: .gray
        case .cancelled: AppPalette.critical
        }
    }
}


/// Notiz zu einer Buchung, z. B. wofür eine Überweisung war. Gespeichert
/// wird beim Verlassen des Felds, mit ⏎ oder beim Wechsel der Buchung,
/// nicht bei jedem Tastendruck (ein Undo-Schritt pro Bearbeitung).
private struct TransactionNoteEditor: View {
    let note: String?
    let onCommit: (String?) -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(note: String?, onCommit: @escaping (String?) -> Void) {
        self.note = note
        self.onCommit = onCommit
        _draft = State(initialValue: note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Notiz").eyebrowStyle()
            TextField("Wofür war das?", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...6)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onChange(of: note) { _, newValue in
                    if !isFocused { draft = newValue ?? "" }
                }
                .onDisappear(perform: commit)
                .accessibilityLabel("Notiz")
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        onCommit(trimmed.isEmpty ? nil : trimmed)
    }
}
