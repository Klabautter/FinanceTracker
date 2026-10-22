import SwiftUI

/// Kalenderkachel: Tag groß, Monat klein.
struct DateBadge: View {
    let date: Date
    var tint: Color = AppPalette.brand

    var body: some View {
        VStack(spacing: 0) {
            Text(date, format: .dateTime.month(.abbreviated))
                .font(.system(size: 9, weight: .medium))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(date, format: .dateTime.day())
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
        }
        .frame(width: 34, height: 34)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(AppPalette.hairline, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

/// Zeilen-Button mit dezentem Hover-/Press-Hintergrund.
struct RowHighlightButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.07 : (isHovering ? 0.04 : 0)))
            )
            .onHover { isHovering = $0 }
    }
}

/// Farbauswahl als Reihe runder Farbfelder statt eines Namensmenüs.
struct ColorSwatchPicker<Token: Hashable>: View {
    let tokens: [Token]
    @Binding var selection: Token
    let color: (Token) -> Color
    let name: (Token) -> String
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tokens, id: \.self) { token in
                Button {
                    selection = token
                } label: {
                    Circle()
                        .fill(color(token))
                        .frame(width: size, height: size)
                        .overlay {
                            if selection == token {
                                Circle().strokeBorder(Color.white, lineWidth: 2).padding(2)
                                Image(systemName: "checkmark")
                                    .font(.system(size: size * 0.42, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(name(token))
                .accessibilityLabel(name(token))
                .accessibilityAddTraits(selection == token ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Native Tabelle/Liste als eingerückte Karte auf der Arbeitsfläche.
    func tableCard(horizontalPadding: CGFloat = AppLayout.pageHorizontalPadding) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AppPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous).strokeBorder(AppPalette.hairline))
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, horizontalPadding)
    }
}

/// Sheet-Rahmen: auf macOS ein eigener Kopf ohne `NavigationStack`
/// (dessen Chrome reserviert in macOS-26-Sheets großen Leerraum und
/// zentriert den Inhalt); Bestätigen/Abbrechen aus `.toolbar` erscheinen dort
/// als native Dialogleiste. Auf iOS bleibt es ein `NavigationStack`.
struct AdaptiveSheet<Content: View>: View {
    let title: String
    var subtitle: String?
    private let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            SheetHeader(title: title, subtitle: subtitle)
                .padding(.horizontal, AppSpacing.xl)
                .padding(.top, AppSpacing.l)
                .padding(.bottom, AppSpacing.xs)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(AppPalette.canvas)
        #else
        NavigationStack {
            content
                .navigationTitle(title)
        }
        #endif
    }
}

/// Umbrechendes Layout für Chips (Tags, Filter).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map { $0.width }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(maxWidth: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if proposedWidth > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [], y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
