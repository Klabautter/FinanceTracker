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

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.width
            HStack(spacing: 0) {
                content
                    .frame(width: isPresented ? max(available - paneWidth - 1, 0) : available, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .clipped()
                if isPresented {
                    Divider()
                    // Feste Breite: Beim Ein-/Ausblenden der Seitenleiste
                    // ändert sich nur die Liste, die Spalte wird nicht bei
                    // jedem Animationsschritt neu umgebrochen.
                    pane
                        .frame(width: paneWidth)
                        .frame(maxHeight: .infinity)
                        .accessibilityLabel(paneAccessibilityLabel)
                }
            }
        }
    }
}
