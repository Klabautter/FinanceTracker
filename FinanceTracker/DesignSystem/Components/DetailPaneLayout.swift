import SwiftUI

/// Liste mit Detailspalte rechts. Die Spalte bleibt immer vollständig im
/// Fenster: Im schmalen Fenster (z. B. Halbbild) bekommt die Liste genau den
/// Rest der Breite; Tabellen scrollen dann seitlich, statt die Spalte aus
/// dem Fenster zu schieben oder von ihr verdeckt zu werden.
///
/// Der GeometryReader nimmt immer die angebotene Breite an. So kann der
/// Bereich schrumpfen, wenn die linke Seitenleiste aufgeht; eine feste
/// Listenbreite würde das blockieren und die Spalte hinausschieben.
///
/// Bewusst kein `.inspector`: der native Split-Container nimmt die ideale
/// Höhe seines Inhalts an (macOS-UI-Besonderheit).
struct DetailPaneLayout<Content: View, Pane: View>: View {
    let isPresented: Bool
    var paneWidth: CGFloat = 320
    var paneAccessibilityLabel: String
    @ViewBuilder var content: Content
    @ViewBuilder var pane: Pane

    /// Vom Nutzer gezogene Breite, für alle Detailspalten gemeinsam gemerkt.
    @AppStorage("detailPaneWidth") private var storedWidth: Double = 0
    @State private var dragStartWidth: CGFloat?

    static var minimumPaneWidth: CGFloat { 280 }
    static var maximumPaneWidth: CGFloat { 520 }
    /// Die Liste behält mindestens diese Breite.
    static var minimumContentWidth: CGFloat { 360 }

    /// Gezogene oder vorgegebene Breite, begrenzt auf den verfügbaren Platz.
    static func clampedWidth(_ desired: CGFloat, available: CGFloat) -> CGFloat {
        let upper = max(minimumPaneWidth, min(maximumPaneWidth, available - minimumContentWidth))
        return min(max(desired, minimumPaneWidth), upper)
    }

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.width
            let width = Self.clampedWidth(storedWidth > 0 ? CGFloat(storedWidth) : paneWidth, available: available)
            HStack(spacing: 0) {
                content
                    .frame(width: isPresented ? max(available - width - 1, 0) : available, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .clipped()
                if isPresented {
                    Divider()
                        .overlay {
                            // Breiter, unsichtbarer Griff zum Ziehen.
                            Color.clear
                                .frame(width: 8)
                                .contentShape(Rectangle())
                                #if os(macOS)
                                .onHover { inside in
                                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                                }
                                #endif
                                .gesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            let start = dragStartWidth ?? width
                                            dragStartWidth = start
                                            storedWidth = Double(Self.clampedWidth(start - value.translation.width, available: available))
                                        }
                                        .onEnded { _ in dragStartWidth = nil }
                                )
                                .accessibilityLabel("Breite der Detailspalte")
                        }
                    // Feste Breite: Beim Ein-/Ausblenden der Seitenleiste
                    // ändert sich nur die Liste, die Spalte wird nicht bei
                    // jedem Animationsschritt neu umgebrochen.
                    pane
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .accessibilityLabel(paneAccessibilityLabel)
                }
            }
        }
    }
}
