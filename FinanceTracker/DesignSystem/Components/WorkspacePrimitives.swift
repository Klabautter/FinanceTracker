import SwiftUI

// MARK: - Page header

/// Shared title/context/action row for pages and focused sheets.
struct PageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var eyebrow: String?
    private let accessory: Accessory

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        eyebrow: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.eyebrow = eyebrow
        self.accessory = accessory()
    }

    var body: some View {
        Group {
            if Accessory.self == EmptyView.self {
                heading
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: AppSpacing.m) {
                        heading
                        Spacer(minLength: AppSpacing.m)
                        accessory
                    }
                    .frame(minWidth: AppLayout.pageHeaderHorizontalMinimumWidth, alignment: .leading)

                    VStack(alignment: .leading, spacing: AppSpacing.m) {
                        heading
                        accessory
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: AppSpacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    Text(eyebrow).eyebrowStyle()
                }
                Text(title)
                    .font(AppTypography.pageTitle)
                    .tracking(-0.4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(AppTypography.supporting)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension PageHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, eyebrow: String? = nil) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, eyebrow: eyebrow) { EmptyView() }
    }
}

// MARK: - Section card

enum PageSectionChrome {
    /// Eigenständige Inhaltskarte (Standard).
    case card
    /// Nur Überschrift und Inhalt, für Abschnitte innerhalb einer Karte.
    case plain
}

/// A section with one clear heading, optional context and an optional action.
struct PageSection<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var chrome: PageSectionChrome
    private let content: Content
    private let accessory: Accessory

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        chrome: PageSectionChrome = .card,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.chrome = chrome
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        let stack = VStack(alignment: .leading, spacing: AppLayout.contentSpacing) {
            HStack(alignment: .center, spacing: AppSpacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppTypography.sectionTitle)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(AppTypography.metadata)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: AppSpacing.m)
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)

        switch chrome {
        case .card: stack.financeCard()
        case .plain: stack
        }
    }
}

extension PageSection where Accessory == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        chrome: PageSectionChrome = .card,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, chrome: chrome, content: content) { EmptyView() }
    }
}

/// Kleiner Text-Link-Button im Markenakzent (z. B. „Alle anzeigen").
struct SectionLinkButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(AppTypography.metadata.weight(.medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Metrics

struct MetricStripItem: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
    var caption: String?
    var tone: AppTone
    var accessibilityValue: String?
    var systemImage: String?

    init(
        id: String? = nil,
        label: String,
        value: String,
        caption: String? = nil,
        tone: AppTone = .neutral,
        accessibilityValue: String? = nil,
        systemImage: String? = nil
    ) {
        self.id = id ?? label
        self.label = label
        self.value = value
        self.caption = caption
        self.tone = tone
        self.accessibilityValue = accessibilityValue
        self.systemImage = systemImage
    }
}

/// Kennzahlen als ruhige Zeile in einer Fläche, getrennt durch Haarlinien.
struct MetricStrip: View {
    let metrics: [MetricStripItem]
    var emphasizesFirstMetric = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    if index > 0 {
                        Rectangle().fill(AppPalette.hairline).frame(width: 1)
                    }
                    MetricTile(metric: metric, isEmphasized: emphasizesFirstMetric && index == 0)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: CGFloat(metrics.count) * 160, alignment: .leading)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 0, alignment: .leading)],
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    MetricTile(metric: metric, isEmphasized: emphasizesFirstMetric && index == 0)
                }
            }
        }
        .appSurface(.groupedContent)
        .accessibilityElement(children: .contain)
    }
}

struct MetricTile: View {
    let metric: MetricStripItem
    var isEmphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(metric.label)
                .eyebrowStyle()
                .lineLimit(1)
            Text(metric.value)
                .accessibilityLabel(metric.accessibilityValue ?? metric.value)
                .font(isEmphasized ? AppTypography.largeMetric : AppTypography.metric)
                .tracking(-0.3)
                .monospacedDigit()
                .foregroundStyle(metric.tone.foregroundColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption = metric.caption {
                Text(caption)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hero

/// Die wichtigste Zahl einer Seite: rein typografisch, ohne Farbfläche.
/// Nebenkennzahlen stehen rechts, durch Haarlinien getrennt.
struct HeroPanel<Footer: View>: View {
    let eyebrow: String
    let value: String
    var valueAccessibilityLabel: String?
    var caption: String?
    var valueTone: AppTone = .neutral
    var systemImage: String?
    var metrics: [MetricStripItem] = []
    private let footer: Footer

    init(
        eyebrow: String,
        value: String,
        valueAccessibilityLabel: String? = nil,
        caption: String? = nil,
        valueTone: AppTone = .neutral,
        systemImage: String? = nil,
        metrics: [MetricStripItem] = [],
        @ViewBuilder footer: () -> Footer
    ) {
        self.eyebrow = eyebrow
        self.value = value
        self.valueAccessibilityLabel = valueAccessibilityLabel
        self.caption = caption
        self.valueTone = valueTone
        self.systemImage = systemImage
        self.metrics = metrics
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: AppSpacing.xl) {
                    primary
                    Spacer(minLength: AppSpacing.l)
                    if !metrics.isEmpty { metricRow }
                }
                .frame(minWidth: metrics.isEmpty ? 0 : 640)

                VStack(alignment: .leading, spacing: AppSpacing.l) {
                    primary
                    if !metrics.isEmpty { metricRow }
                }
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var primary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow).eyebrowStyle()
            Text(value)
                .font(AppTypography.heroMetric)
                .tracking(-1.2)
                .monospacedDigit()
                .foregroundStyle(valueTone.foregroundColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel(valueAccessibilityLabel ?? value)
            if let caption {
                Text(caption)
                    .font(AppTypography.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var metricRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Rectangle().fill(AppPalette.hairline).frame(width: 1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(metric.label).eyebrowStyle()
                    Text(metric.value)
                        .font(AppTypography.metric)
                        .tracking(-0.3)
                        .monospacedDigit()
                        .foregroundStyle(metric.tone.foregroundColor)
                        .lineLimit(1)
                        .accessibilityLabel(metric.accessibilityValue ?? metric.value)
                    if let caption = metric.caption {
                        Text(caption)
                            .font(AppTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, AppSpacing.l)
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize()
    }
}

extension HeroPanel where Footer == EmptyView {
    init(
        eyebrow: String,
        value: String,
        valueAccessibilityLabel: String? = nil,
        caption: String? = nil,
        valueTone: AppTone = .neutral,
        systemImage: String? = nil,
        metrics: [MetricStripItem] = []
    ) {
        self.init(
            eyebrow: eyebrow, value: value, valueAccessibilityLabel: valueAccessibilityLabel,
            caption: caption, valueTone: valueTone, systemImage: systemImage, metrics: metrics
        ) { EmptyView() }
    }
}

// MARK: - Building blocks

/// Kreisförmiges Symbol mit getönter Fläche (Kategorien, Konten).
struct IconTile: View {
    let systemName: String
    var color: Color = .secondary
    var size: CGFloat = 28
    /// Kräftige Variante: volle Farbe, weißes Symbol.
    var filled = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(filled ? Color.white : color)
            .frame(width: size, height: size)
            .background(Circle().fill(filled ? color : color.opacity(0.15)))
            .accessibilityHidden(true)
    }
}

/// Kleiner Farbpunkt zur Kennzeichnung (Kategorie, Tag, Datenreihe).
struct ColorDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Fortschrittsbalken mit Tonfarbe und Überlaufmarkierung.
struct FinanceProgressBar: View {
    /// 0…1+ (Werte > 1 zeigen eine Überschreitung).
    let fraction: Double
    var tone: AppTone = .neutral
    var height: CGFloat = 4
    /// Optionale Markierung (z. B. erwarteter Stand heute) 0…1.
    var marker: Double?

    var body: some View {
        GeometryReader { proxy in
            let clamped = max(0, min(1, fraction.isFinite ? fraction : 0))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tone == .neutral ? Color.primary.opacity(0.7) : tone.foregroundColor)
                    .frame(width: max(clamped > 0 ? height : 0, proxy.size.width * clamped))
                if let marker, marker > 0, marker < 1 {
                    Capsule()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: height + 6)
                        .offset(x: proxy.size.width * marker - 1)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int(((fraction.isFinite ? fraction : 0) * 100).rounded())) Prozent")
    }
}

struct StatusBadge: View {
    let title: String
    var tone: AppTone = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone == .neutral ? Color.secondary : tone.foregroundColor)
                .frame(width: 6, height: 6)
            Text(title)
        }
        .font(AppTypography.metadata.weight(.medium))
        .foregroundStyle(tone == .neutral ? Color.secondary : tone.foregroundColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.primary.opacity(0.05))
        )
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tone.accessibilityPrefix): \(title)")
    }
}

struct InlineNotice: View {
    let message: String
    var title: String?
    var tone: AppTone = .information
    var systemImage: String?

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.m) {
            Image(systemName: systemImage ?? tone.defaultSystemImage)
                .font(.callout)
                .foregroundStyle(tone.foregroundColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(AppTypography.supporting.weight(.semibold))
                }
                Text(message)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(AppPalette.sunken)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        [tone.accessibilityPrefix, title, message]
            .compactMap { $0 }
            .joined(separator: ": ")
    }
}

/// Einheitliches Suchfeld im Karten-Look.
struct FinanceSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: AppSpacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Suche löschen")
                .help("Suche löschen")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AppPalette.sunken)
        )
    }
}

/// Search and filters share one responsive functional row.
struct FilterBar<FilterContent: View>: View {
    @Binding private var searchText: String
    let searchPrompt: String
    private let filterContent: FilterContent

    init(
        searchText: Binding<String>,
        searchPrompt: String,
        @ViewBuilder filters: () -> FilterContent
    ) {
        _searchText = searchText
        self.searchPrompt = searchPrompt
        self.filterContent = filters()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppSpacing.m) {
                filterContent
                Spacer(minLength: AppSpacing.m)
                FinanceSearchField(text: $searchText, prompt: searchPrompt)
                    .frame(width: 260)
            }
            .frame(minWidth: AppLayout.filterBarHorizontalMinimumWidth)

            VStack(alignment: .leading, spacing: AppSpacing.s) {
                filterContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                FinanceSearchField(text: $searchText, prompt: searchPrompt)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Sheets

/// Kopf für fokussierte Dialoge: Symbolkachel, Titel und Kontext.
struct SheetHeader: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var color: Color = AppPalette.brand

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTypography.sheetTitle)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Consistent sheet hierarchy for focused form tasks. It supplies structure,
/// not navigation or save logic, and therefore stays reusable across features.
struct FormSheetScaffold<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    private let content: Content
    private let actions: Actions
    private let showsActions: Bool

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
        self.actions = actions()
        self.showsActions = true
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, subtitle: subtitle, systemImage: systemImage)
                .padding(.horizontal, AppSpacing.xl)
                .padding(.top, AppSpacing.xl)
                .padding(.bottom, AppSpacing.l)
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSpacing.xl)
                    .padding(.bottom, AppSpacing.xl)
            }
            if showsActions {
                Divider()
                HStack(spacing: AppSpacing.s) {
                    Spacer(minLength: 0)
                    actions
                }
                .padding(AppSpacing.l)
                .background(AppPalette.card)
            }
        }
        .background(AppPalette.canvas)
        .frame(
            idealWidth: AppLayout.formSheetIdealWidth,
            maxWidth: AppLayout.formSheetMaximumWidth
        )
        .accessibilityElement(children: .contain)
    }
}

extension FormSheetScaffold where Actions == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
        self.actions = EmptyView()
        self.showsActions = false
    }
}

// MARK: - Workspace environment

/// Mounted workspaces retain local state, but only the selected page owns
/// window chrome and commands. Opacity alone does not stop SwiftUI preferences.
private struct WorkspaceActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isWorkspaceActive: Bool {
        get { self[WorkspaceActiveKey.self] }
        set { self[WorkspaceActiveKey.self] = newValue }
    }
}

private struct WorkspaceToolbar<Items: ToolbarContent>: ViewModifier {
    @Environment(\.isWorkspaceActive) private var isActive
    let items: Items
    func body(content: Content) -> some View {
        content.toolbar { if isActive { items } }
    }
}

extension View {
    func workspaceToolbar<Items: ToolbarContent>(@ToolbarContentBuilder _ items: () -> Items) -> some View {
        modifier(WorkspaceToolbar(items: items()))
    }

    @ViewBuilder
    func workspaceNavigationTitle(_ title: String) -> some View {
        #if os(macOS)
        self
        #else
        navigationTitle(title)
        #endif
    }
}

/// A stable title above native tables and forms, including their empty states.
extension View {
    func workspaceHeading(_ title: String, subtitle: String? = nil, eyebrow: String? = nil) -> some View {
        VStack(spacing: 0) {
            PageHeader(title, subtitle: subtitle, eyebrow: eyebrow)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppLayout.pageHorizontalPadding)
                .padding(.top, AppSpacing.xl)
                .padding(.bottom, AppSpacing.l)
            self
        }
        .background(AppPalette.canvas)
    }
}
